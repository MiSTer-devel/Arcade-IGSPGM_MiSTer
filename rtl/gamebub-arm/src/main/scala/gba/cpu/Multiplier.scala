package gba.cpu

import chisel3._
import chisel3.util._

class Multiplier extends Module {
  val io = IO(new Bundle {
    val enable = Input(Bool())

    val a = Input(UInt(32.W))
    val b = Input(UInt(32.W))

    val start = Input(Bool())
    val loadAccumulator = Input(Bool())
    val accumulate = Input(Bool())
    val signed = Input(Bool())
    val long = Input(Bool())

    val outLo = Output(UInt(32.W))
    val outHi = Output(UInt(32.W))
    val done = Output(Bool())
    val outFlagZ = Output(Bool())
    val outFlagN = Output(Bool())

    /// Save/restore state port. Local words:
    ///   0: accumulator[31:0]  1: accumulator[63:32]
    ///   2: output[31:0]       3: output[63:32]
    ///   4: counter
    val state = new StatePort
  })

  val accumulator = Reg(UInt(64.W))
  val output = Reg(UInt(64.W))
  val counter = Reg(UInt(2.W))
  // Timing-closure staging (see the start block below): the 32x32 multiply's operand
  // read + DSP cascade is too deep to also feed a register in one cycle, so the work
  // is spread across the cycles the FSM already spends (ARM m-cycle early termination),
  // adding no instruction cycle:
  //   m == 1 (numCycles 0): small 32x9 multiply + accumulate, one cycle (no spare).
  //   m == 2 (numCycles 1): sized 32x17 product this cycle, accumulate add deferred.
  //   m >= 3 (numCycles 2..3): latch operands, multiply from *registers* next cycle
  //                            (DSP launches behind a reg, no operand-read in front),
  //                            accumulate add the cycle after.
  // aReg/bReg/product/multPending/addPending are all dead at instruction boundaries
  // (freeze only engages once `done`), so none needs a savestate word.
  val aReg = Reg(UInt(32.W))
  val bReg = Reg(UInt(32.W))
  val product = Reg(UInt(64.W))
  val multPending = RegInit(false.B)
  val addPending = RegInit(false.B)

  // Determine cycle length.
  // Early termination based on the number of leading 0s or 1s.
  // For unsigned long multiply, it's only leading 0s.
  val prefixZeroes = VecInit(!io.b(31, 24).orR, !io.b(23, 16).orR, !io.b(15, 8).orR, !io.b(7, 0).orR).asUInt
  val prefixOnes = VecInit(io.b(31, 24).andR, io.b(23, 16).andR, io.b(15, 8).andR, io.b(7, 0).andR).asUInt
  val termOnes = !(io.long && !io.signed)
  val numCycles = MuxCase(3.U, Seq(
    (prefixZeroes(2, 0) === "b111".U || (prefixOnes(2, 0) === "b111".U && termOnes)) -> 0.U,
    (prefixZeroes(1, 0) === "b11".U || (prefixOnes(1, 0) === "b11".U && termOnes)) -> 1.U,
    (prefixZeroes(0, 0) === "b1".U || (prefixOnes(0, 0) === "b1".U && termOnes)) -> 2.U,
  ))

  val augend = Mux(io.accumulate, accumulator, 0.U)

  // Sized products for the short multiplies (m == 1, m == 2). When Rs early-terminates
  // at m bytes, the bits above byte m are all equal to the sign bit, so the full
  // product equals a * b[low 8*m+1 bits]. A narrower multiply closes in a single cycle
  // where the full 32x32 cannot.
  //   Signedness: signed long uses signed; unsigned long uses unsigned (m there only
  //   via leading zeroes, so the extra bit is 0); non-long (MUL/MLA) only needs the
  //   low 32 bits, which a signed multiply reproduces for both prefix cases — so force
  //   signed unless this is an unsigned *long* multiply.
  val smallSigned = io.signed || !io.long
  val b9  = io.b(8, 0)
  val b17 = io.b(16, 0)
  val product9S  = Wire(SInt(64.W)); product9S  := io.a.asSInt * b9.asSInt
  val product9U  = Wire(UInt(64.W)); product9U  := io.a * b9
  val product9   = Mux(smallSigned, product9S.asUInt, product9U)   // m == 1 (32x9)
  val product17S = Wire(SInt(64.W)); product17S := io.a.asSInt * b17.asSInt
  val product17U = Wire(UInt(64.W)); product17U := io.a * b17
  val product17  = Mux(smallSigned, product17S.asUInt, product17U) // m == 2 (32x17)

  // Full 32x32 product from the *latched* operands (m >= 3). Launching the DSP from
  // registers keeps the ~8 ns operand-read out of this cycle's path.
  val regProduct = Mux(io.signed, (aReg.asSInt * bReg.asSInt).asUInt, aReg * bReg)

  when (io.enable) {
    when (io.loadAccumulator) {
      accumulator := Cat(io.a, io.b)
    }
    when (io.start) {
      when (numCycles === 0.U) {
        // m == 1: small 32x9 multiply + accumulate, all in this cycle (no spare cycle).
        output := product9 + augend
        multPending := false.B
        addPending := false.B
      } .elsewhen (numCycles === 1.U) {
        // m == 2: capture the sized 32x17 product now; defer the add to the one
        // countdown cycle the FSM already spends.
        product := product17
        multPending := false.B
        addPending := true.B
      } .otherwise {
        // m >= 3: latch the operands; the multiply runs next cycle from registers.
        aReg := io.a
        bReg := io.b
        multPending := true.B
        addPending := false.B
      }
      counter := numCycles
    } .elsewhen (multPending) {
      // Registered-operand multiply (m >= 3): the DSP launches behind a register.
      product := regProduct
      multPending := false.B
      addPending := true.B
    } .elsewhen (addPending) {
      // Deferred 64-bit accumulate add — lands on a countdown cycle the FSM already
      // spends before `done`, so no instruction cycle is added.
      output := product + augend
      addPending := false.B
    }
    when (counter > 0.U) {
      counter := counter - 1.U
    }
  }

  // Save/restore: 64-bit registers are read/written 32 bits at a time via
  // read-modify-write. Placed after the enable block so it wins while frozen.
  io.state.readData := MuxLookup(io.state.address, 0.U)(Seq(
    0.U -> accumulator(31, 0),
    1.U -> accumulator(63, 32),
    2.U -> output(31, 0),
    3.U -> output(63, 32),
    4.U -> counter,
  ))
  when (io.state.writeEnable) {
    switch (io.state.address) {
      is (0.U) { accumulator := Cat(accumulator(63, 32), io.state.writeData) }
      is (1.U) { accumulator := Cat(io.state.writeData, accumulator(31, 0)) }
      is (2.U) { output := Cat(output(63, 32), io.state.writeData) }
      is (3.U) { output := Cat(io.state.writeData, output(31, 0)) }
      is (4.U) { counter := io.state.writeData(1, 0) }
    }
  }

  val zeroLo = output(31, 0) === 0.U
  val zeroHi = output(63, 32) === 0.U

  io.done := counter === 0.U
  io.outLo := output(31, 0)
  io.outHi := output(63, 32)
  io.outFlagZ := Mux(io.long, zeroLo && zeroHi, zeroLo)
  io.outFlagN := Mux(io.long, output(63), output(31))
}
