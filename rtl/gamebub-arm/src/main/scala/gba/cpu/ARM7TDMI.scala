package gba.cpu

import chisel3._
import chisel3.util._
import chisel3.experimental.BundleLiterals._
import gba.mem.{BusAccessWidth, BusInterface}
import lib.log.Logger

/// ARM7TDMI-S compatible processor as found in the GBA
class ARM7TDMI extends Module {
  val io = IO(new Bundle {
    /// Global enable signal for emulation
    val enable = Input(Bool())
    /// Debug output
    val debug = Output(new CpuDebug())

    /// Memory bus interface
    val mem = new BusInterface
    /// **Active-High** fast interrupt request
    val FIQ = Input(Bool())
    /// **Active-High** interrupt request
    val IRQ = Input(Bool())

    /// Save/restore: indexed 32-bit access to the full machine state (56 words).
    val state = new StatePort
    /// Request the CPU to halt at the next safe (instruction-boundary) point.
    val saveReq = Input(Bool())
    /// High (and held) once the CPU is frozen at a safe point for save/restore.
    val safe = Output(Bool())
  })
  val logger = Logger("cpu", enable = io.enable)

  // Save/restore handshake: when saveReq is asserted, run until the next
  // instruction boundary (with the multiplier idle), then freeze by gating
  // `enable` low and hold `safe`. While frozen, all `when(enable)` updates stop;
  // the host reads/writes state over `io.state`. Deasserting saveReq resumes from
  // exactly the frozen cycle. The host must also snapshot external memory so the
  // pending instruction prefetch re-presents identically on resume.
  // `freeze` is driven below, once controlUnit and multiplier are instantiated.
  val freeze = Wire(Bool())
  val enable = io.enable && io.mem.CLKEN && !freeze

  ////////////////////////////////// Busses and Registers //////////////////////////////////
  val memAddrReg = Reg(UInt(32.W))
  val memReadDataReg = Reg(UInt(32.W))

  val aBus = Wire(UInt(32.W))
  val bBus = Wire(UInt(32.W))
  val cBus = Wire(UInt(32.W))
  val pcBus = Wire(UInt(32.W))
  val aluBus = Wire(UInt(32.W))
  val aluConditionOut = Wire(new ConditionFlags)
  val incrementerBus = Wire(UInt(32.W))
  val control = Wire(new ControlSignals)
  val cpsrBus = Wire(new ProgramStatusRegister)
  bBus := DontCare

  //////////////////////////////// Instruction Fetch & Decode //////////////////////////////
  val decodeUnit = Module(new Decoder)
  decodeUnit.io.enable := enable
  decodeUnit.io.advancePipeline := control.advancePipeline
  decodeUnit.io.flushPipeline := control.flushPipeline
  decodeUnit.io.readData := io.mem.RDATA
  decodeUnit.io.readAddress := memAddrReg
  decodeUnit.io.thumb := cpsrBus.thumb

  ////////////////////////////////////// Control Unit //////////////////////////////////////
  val controlUnit = Module(new Control)
  controlUnit.io.enable := enable
  controlUnit.io.nextInstruction := decodeUnit.io.decoded
  controlUnit.io.fiq := io.FIQ
  controlUnit.io.irq := io.IRQ
  control := controlUnit.io.signals
  when (control.busB === BusBValue.Immediate) {
    bBus := control.immediate
  }

  ///////////////////////////////////// Register File //////////////////////////////////////
  // 0-15: r0-r15
  // 16: 13_svc, 17: 14_svc,
  // 18: 13_abt, 19: 14_abt,
  // 20: 13_und, 21: 14_und,
  // 22: 13_irq, 23: 14_irq
  // 24-30: 8-14 _fiq
  val registers = RegInit(VecInit.fill(31)(0.U(32.W)))
  private def bankRegIndex(index: UInt, mode: CpuMode.Type = control.regBankMode): UInt = {
    val offset = WireDefault(0.U(5.W))
    when (mode === CpuMode.Fiq && index >= 8.U && index <= 14.U) {
      offset := (24 - 8).U(5.W)
    } .elsewhen (index === 13.U || index === 14.U) {
      when (mode === CpuMode.Supervisor) {
        offset := (16 - 13).U(5.W)
      } .elsewhen (mode === CpuMode.Abort) {
        offset := (18 - 13).U(5.W)
      } .elsewhen (mode === CpuMode.Undefined) {
        offset := (20 - 13).U(5.W)
      } .elsewhen (mode === CpuMode.Irq) {
        offset := (22 - 13).U(5.W)
      }
    }
    index + offset
  }

  // Banked register *read* that avoids the bank-offset adder sitting in series
  // ahead of a 31-deep Vec read mux (the dominant chunk of the 50 MHz critical
  // read path). The common case (r0-r15) is a direct 16:1 read; the few banked
  // physical copies (16-30) are read in parallel and selected late by mode.
  // Must stay bit-identical to bankRegIndex() for every read. Used for operand
  // reads only; writes still go through bankRegIndex (off the critical path).
  private def bankedRead(index: UInt, mode: CpuMode.Type): UInt = {
    val base = registers(index)                       // r0..r15, direct 16:1
    val fiqBank = MuxLookup(index, base)(Seq(          // r8..r14 -> phys 24..30
      8.U  -> registers(24.U),
      9.U  -> registers(25.U),
      10.U -> registers(26.U),
      11.U -> registers(27.U),
      12.U -> registers(28.U),
      13.U -> registers(29.U),
      14.U -> registers(30.U),
    ))
    val hi = index === 14.U                            // false => r13, true => r14
    val shadow = MuxLookup(mode, base)(Seq(            // r13/r14 per privileged mode
      CpuMode.Supervisor -> Mux(hi, registers(17.U), registers(16.U)),
      CpuMode.Abort      -> Mux(hi, registers(19.U), registers(18.U)),
      CpuMode.Undefined  -> Mux(hi, registers(21.U), registers(20.U)),
      CpuMode.Irq        -> Mux(hi, registers(23.U), registers(22.U)),
    ))
    val is1314 = (index === 13.U) || (index === 14.U)
    val fiqHit = (mode === CpuMode.Fiq) && (index >= 8.U) && (index <= 14.U)
    Mux(fiqHit, fiqBank, Mux(is1314, shadow, base))
  }

  val cpsr = RegInit((new ProgramStatusRegister).Lit(
    _.mode -> CpuMode.System,
    _.thumb -> false.B,
    _.irqDisable -> true.B,
    _.fiqDisable -> true.B,
    _.padding -> 0.U,
    _.cond -> (new ConditionFlags).Lit(
      _.n -> false.B,
      _.z -> false.B,
      _.c -> false.B,
      _.v -> false.B,
    ),
  ))
  val spsrVec = Reg(Vec(5, new ProgramStatusRegister))
  val spsrIndex = MuxLookup(control.regBankMode, 0.U)(Seq(
    CpuMode.Supervisor -> 0.U,
    CpuMode.Abort -> 1.U,
    CpuMode.Undefined -> 2.U,
    CpuMode.Irq -> 3.U,
    CpuMode.Fiq -> 4.U,
  ))
  val spsr = spsrVec(spsrIndex)
  val modeHasSpsr = (control.regBankMode =/= CpuMode.User) && (control.regBankMode =/= CpuMode.System)
  val modePrivileged = cpsr.mode =/= CpuMode.User
  val nextCpsr = WireDefault(cpsr)

  controlUnit.io.currentStatus := cpsr
  controlUnit.io.nextStatus := nextCpsr
  cpsrBus := cpsr
  val pc = registers(15)
  pcBus := pc
  // Operand reads bank purely off the *current* CPSR mode (a stable register
  // output), NOT control.regBankMode. control.regBankMode is overridden to the
  // exception's newMode inside an `execute`-gated (condition-eval) branch, which
  // would otherwise place the condition evaluation in series before the read-port
  // bankRegIndex adder — the front of the 50 MHz critical path. The exception
  // cycle only reads r15 (PC, unbanked), so newMode is never needed for a read;
  // it is still used for the banked *writeback* below. This is timing-only.
  val regReadBankMode = cpsr.mode
  aBus := bankedRead(control.regReadA, regReadBankMode)
  when (control.busB === BusBValue.RegisterB) {
    bBus := bankedRead(control.regReadB, regReadBankMode)
  } .elsewhen (control.busB === BusBValue.Cpsr) {
    bBus := cpsr.asUInt
  } .elsewhen (control.busB === BusBValue.Spsr) {
    when (modeHasSpsr) {
      bBus := spsr.asUInt
    } .otherwise {
      // Modes without SPSR apparently return CPSR on a read
      bBus := cpsr.asUInt
    }
  }
  cBus := bankedRead(
    control.regReadC,
    Mux(control.regUserReadC, CpuMode.User, regReadBankMode)
  )
  when (enable) {
    when (control.regWriteEnable) {
      logger.debug(cf"  reg write [${control.regWriteIndex}] <- ${aluBus}%x")
      // Writes to PC are always aligned by 2, but there's no need to do that here,
      // because r15 writes via regWriteEnable are always followed by an incrementer write.
      registers(
        bankRegIndex(
          control.regWriteIndex,
          Mux(control.regUserWrite, CpuMode.User, control.regBankMode)
        )) := aluBus
    }
    when (control.cpsrUpdateCond) {
      nextCpsr.cond := aluConditionOut
    }
    when (control.cpsrUpdateThumb) {
      nextCpsr.thumb := aBus(0)
    }
    when (control.cpsrUpdateFields(0) && modePrivileged) {
      nextCpsr.mode := suppressEnumCastWarning { aluBus(4, 0).asTypeOf(CpuMode()) }
      nextCpsr.thumb := aluBus(5)
      nextCpsr.fiqDisable := aluBus(6)
      nextCpsr.irqDisable := aluBus(7)
    }
    when (control.cpsrUpdateFields(1)) {
      nextCpsr.cond := aluBus(31, 28).asTypeOf(new ConditionFlags)
    }
    when (control.spsrUpdateFields(0) && modeHasSpsr) {
      spsr.mode := suppressEnumCastWarning { aluBus(4, 0).asTypeOf(CpuMode()) }
      spsr.thumb := aluBus(5)
      spsr.fiqDisable := aluBus(6)
      spsr.irqDisable := aluBus(7)
    }
    when (control.spsrUpdateFields(1) && modeHasSpsr) {
      spsr.cond := aluBus(31, 28).asTypeOf(new ConditionFlags)
    }
    when (control.cpsrRestore && modeHasSpsr) {
      nextCpsr := spsr
    }
    when (control.startException) {
      val newMode = control.regBankMode
      nextCpsr.mode := newMode
      nextCpsr.thumb := false.B
      nextCpsr.irqDisable := true.B
      when (newMode === CpuMode.Fiq) { // also in Reset
        nextCpsr.fiqDisable := true.B
      }
      spsr := cpsrBus
    }
    switch (control.pcNext) {
      is (PcNext.Incrementer) {
        // PC is always aligned to 2
        //  THUMB: part of the ARM ARM
        //    ARM: "unpredictable", but seems to be the same behavior
        pc := incrementerBus & "hFFFFFFFE".U(32.W)
      }
    }
    cpsr := nextCpsr
  }

  ///////////////////////////////////// Barrel Shifter /////////////////////////////////////
  val shifter = Module(new Shifter)
  shifter.io.in := bBus
  shifter.io.carryIn := cpsrBus.cond.c
  shifter.io.shiftKind := control.shiftKind
  shifter.io.shiftAmount := control.shiftImmediate
  shifter.io.latchShift := enable && control.shiftDoLatch
  shifter.io.useLatchedShift := control.shiftUseLatched

  ////////////////////////////////////////// ALU ///////////////////////////////////////////
  val alu = Module(new Alu)
  alu.io.a := aBus
  when (control.aluInAAlign4) {
    alu.io.a := aBus & "hFFFFFFFC".U(32.W)
  }
  alu.io.b := shifter.io.out
  alu.io.opcode := control.aluOpcode
  alu.io.flagIn := cpsrBus.cond
  alu.io.shifterCarry := shifter.io.carryOut
  aluBus := alu.io.out
  when (control.aluOutAlign4) {
    aluBus := alu.io.out & "hFFFFFFFC".U(32.W)
  }
  aluConditionOut := alu.io.flagOut

  /////////////////////////////////////// Multiplier ///////////////////////////////////////
  val multiplier = Module(new Multiplier)
  multiplier.io.enable := enable
  multiplier.io.a := aBus
  multiplier.io.b := bBus
  multiplier.io.start := control.multiplyEnable
  multiplier.io.loadAccumulator := control.multiplyLoadAccumulator
  multiplier.io.accumulate := control.multiplyAccumulate
  multiplier.io.signed := control.multiplySigned
  multiplier.io.long := control.multiplyLong
  when (control.busB === BusBValue.MultiplyLo) {
    bBus := multiplier.io.outLo
  } .elsewhen (control.busB === BusBValue.MultiplyHi) {
    bBus := multiplier.io.outHi
  }
  controlUnit.io.multiplierDone := multiplier.io.done
  when (control.cpsrFromMultiply) {
    nextCpsr.cond.z := multiplier.io.outFlagZ
    nextCpsr.cond.n := multiplier.io.outFlagN
  }

  /////////////////////////////////////// Incrementer //////////////////////////////////////
  incrementerBus := memAddrReg + Mux(cpsrBus.thumb && !control.incrementerForceWord, 2.U, 4.U)

  ///////////////////////////////////////// IO Port ////////////////////////////////////////
  val currentMemReadWidth = Reg(BusAccessWidth())
  val lastMemReadWidth = Reg(BusAccessWidth())
  val lastMemReadAlign = Reg(UInt(2.W))
  io.mem.ADDR := memAddrReg
  switch (control.addressSource) {
    is (AddressSource.Incrementer) { io.mem.ADDR := incrementerBus }
    is (AddressSource.Pc) { io.mem.ADDR := pcBus }
    is (AddressSource.Alu) { io.mem.ADDR := aluBus }
    is (AddressSource.Immediate) { io.mem.ADDR := control.immediate }
  }
  when (enable) {
    memAddrReg := io.mem.ADDR
    currentMemReadWidth := io.mem.SIZE
    when (control.latchMemReadData) {
      lastMemReadWidth := currentMemReadWidth
      lastMemReadAlign := memAddrReg(1, 0)
      memReadDataReg := io.mem.RDATA
    }
  }
  val memWriteData = Wire(UInt(32.W))
  when (currentMemReadWidth === BusAccessWidth.Byte) {
    memWriteData := Fill(4, cBus(7, 0))
  } .elsewhen (currentMemReadWidth === BusAccessWidth.Halfword) {
    memWriteData := Fill(2, cBus(15, 0))
  } .otherwise {
    memWriteData := cBus
  }
  when (control.busB === BusBValue.MemReadData) {
    val readData = WireDefault(memReadDataReg)
    bBus := readData

    // For halfword and byte loads, mask out / sign extend bits.
    val maskValue = WireDefault(0.U(8.W))
    when (control.memReadDataSigned) {
      val signByte = Mux(
        lastMemReadWidth === BusAccessWidth.Halfword,
        lastMemReadAlign | 1.U,
        lastMemReadAlign,
      )
      maskValue := Fill(8, memReadDataReg(Cat(signByte, "b111".U(3.W))))
    }
    when (lastMemReadWidth === BusAccessWidth.Byte) {
      readData := Cat(
        Mux(lastMemReadAlign === 3.U, memReadDataReg(31, 24), maskValue),
        Mux(lastMemReadAlign === 2.U, memReadDataReg(23, 16), maskValue),
        Mux(lastMemReadAlign === 1.U, memReadDataReg(15, 8), maskValue),
        Mux(lastMemReadAlign === 0.U, memReadDataReg(7, 0), maskValue),
      )
    } .elsewhen (lastMemReadWidth === BusAccessWidth.Halfword) {
      readData := Cat(
        Mux(lastMemReadAlign(1), memReadDataReg(31, 16), Fill(2, maskValue)),
        Mux(!lastMemReadAlign(1), memReadDataReg(15, 0), Fill(2, maskValue)),
      )
    }
  }
  when (control.shiftByAddressAlign) {
    shifter.io.shiftAmount := lastMemReadAlign << 3
  }

  io.mem.WDATA := memWriteData
  io.mem.WRITE := control.memWrite
  io.mem.SIZE := control.memWidth
  io.mem.MREQ := control.memRequest
  io.mem.SEQ := control.memSequential
  io.mem.LOCK := control.memLock
  io.mem.PROT := control.memProt

  ///////////////////////////////////// Save / Restore /////////////////////////////////////
  // Drive the handshake now that controlUnit and multiplier exist. Once a safe
  // point is reached it is *latched* (`halted`): subsequent state writes during a
  // restore change control state (and thus `atSafePoint`), but the CPU must stay
  // frozen until the host releases `saveReq`.
  val atSafePoint = controlUnit.io.atBoundary && multiplier.io.done
  val halted = RegInit(false.B)
  when (io.saveReq && atSafePoint) { halted := true.B }
  when (!io.saveReq) { halted := false.B }
  freeze := io.saveReq && (halted || atSafePoint)
  io.safe := freeze

  // Route the shared 32-bit state port. Global word map:
  //   0..30 registers, 31 cpsr, 32..36 spsr, 37 memAddrReg, 38 memReadDataReg,
  //   39 {lastMemReadWidth, currentMemReadWidth, lastMemReadAlign},
  //   40..44 Decoder, 45..49 Control, 50..54 Multiplier, 55 Shifter.
  for ((unit, base, end) <- Seq(
    (decodeUnit.io.state, 40, 45), (controlUnit.io.state, 45, 50),
    (multiplier.io.state, 50, 55), (shifter.io.state, 55, 56),
  )) {
    unit.address := io.state.address - base.U
    unit.writeData := io.state.writeData
    unit.writeEnable := io.state.writeEnable && io.state.address >= base.U && io.state.address < end.U
  }

  // Read mux over the whole map.
  io.state.readData := 0.U
  when (io.state.address < 31.U) {
    io.state.readData := registers(io.state.address)
  } .elsewhen (io.state.address === 31.U) {
    io.state.readData := cpsr.asUInt
  } .elsewhen (io.state.address < 37.U) {
    io.state.readData := spsrVec(io.state.address - 32.U).asUInt
  } .elsewhen (io.state.address === 37.U) {
    io.state.readData := memAddrReg
  } .elsewhen (io.state.address === 38.U) {
    io.state.readData := memReadDataReg
  } .elsewhen (io.state.address === 39.U) {
    io.state.readData := Cat(lastMemReadWidth.asUInt.pad(2), currentMemReadWidth.asUInt.pad(2), lastMemReadAlign)
  } .elsewhen (io.state.address < 45.U) {
    io.state.readData := decodeUnit.io.state.readData
  } .elsewhen (io.state.address < 50.U) {
    io.state.readData := controlUnit.io.state.readData
  } .elsewhen (io.state.address < 55.U) {
    io.state.readData := multiplier.io.state.readData
  } .otherwise {
    io.state.readData := shifter.io.state.readData
  }

  // Write the top-level registers (submodules handle their own words). Gated only
  // by writeEnable (independent of `enable`); placed after every when(enable)
  // block so it wins while the CPU is frozen.
  when (io.state.writeEnable) {
    suppressEnumCastWarning {
      when (io.state.address < 31.U) {
        registers(io.state.address) := io.state.writeData
      } .elsewhen (io.state.address === 31.U) {
        cpsr := io.state.writeData.asTypeOf(new ProgramStatusRegister)
      } .elsewhen (io.state.address < 37.U) {
        spsrVec(io.state.address - 32.U) := io.state.writeData.asTypeOf(new ProgramStatusRegister)
      } .elsewhen (io.state.address === 37.U) {
        memAddrReg := io.state.writeData
      } .elsewhen (io.state.address === 38.U) {
        memReadDataReg := io.state.writeData
      } .elsewhen (io.state.address === 39.U) {
        lastMemReadAlign := io.state.writeData(1, 0)
        currentMemReadWidth := io.state.writeData(3, 2).asTypeOf(BusAccessWidth())
        lastMemReadWidth := io.state.writeData(5, 4).asTypeOf(BusAccessWidth())
      }
    }
  }

  ////////////////////////////////////////// Debug /////////////////////////////////////////
  io.debug.registers := VecInit(
    (0 until 16).map(i => registers(bankRegIndex(i.U)))
  )
  io.debug.cpsr := cpsr.asUInt
  when (enable) {
    logger.debug(cf" r0: ${registers(0)}%x   r1: ${registers(1)}%x   r2: ${registers(2)}%x   r3: ${registers(3)}%x")
    logger.debug(cf" r4: ${registers(4)}%x   r5: ${registers(5)}%x   r6: ${registers(6)}%x   r7: ${registers(7)}%x")
    logger.debug(cf" r8: ${registers(bankRegIndex(8.U))}%x   r9: ${registers(bankRegIndex(9.U))}%x  r10: ${registers(bankRegIndex(10.U))}%x  r11: ${registers(bankRegIndex(11.U))}%x")
    logger.debug(cf"r12: ${registers(bankRegIndex(12.U))}%x  r13: ${registers(bankRegIndex(13.U))}%x  r14: ${registers(bankRegIndex(14.U))}%x  r15: ${registers(15)}%x")
    logger.debug(cf"cpsr: ${cpsr.asUInt}%x")
  }
}

class ConditionFlags extends Bundle {
  /// Negative or less than
  val n = Bool()
  /// Zero
  val z = Bool()
  /// Carry or borrow or extend
  val c = Bool()
  /// Overflow
  val v = Bool()
}

class ProgramStatusRegister extends Bundle {
  /// [31:28]: Condition flags
  val cond = new ConditionFlags

  /// 20 bits of padding, always read as 0
  val padding = UInt(20.W)

  ///     7: IRQ disable
  val irqDisable = Bool()
  ///     6: FIQ disable
  val fiqDisable = Bool()
  ///     5: State bit
  val thumb = Bool()
  /// [4:0]: Mode bits
  val mode = CpuMode()
}

object CpuMode extends ChiselEnum {
  val User = Value("b10000".U(5.W))
  val Fiq = Value("b10001".U(5.W))
  val Irq = Value("b10010".U(5.W))
  val Supervisor = Value("b10011".U(5.W))
  val Abort = Value("b10111".U(5.W))
  val Undefined = Value("b11011".U(5.W))
  val System = Value("b11111".U(5.W))
}

class CpuDebug extends Bundle {
  val registers = Vec(16, UInt(32.W))
  val cpsr = UInt(32.W)
}