package gba.cpu

import chisel3._
import chisel3.util._

object AluOpcode extends ChiselEnum {
  /// Logical AND (Rd := Rn AND shifter_operand)
  val and = Value
  /// Logical XOR (Rd := Rn XOR shifter_operand)
  val eor = Value
  /// Subtract (Rd := Rn - shifter_operand)
  val sub = Value
  /// Reverse Subtract (Rd := shifter_operand - Rn)
  val rsb = Value
  /// Add (Rd := Rn + shifter_operand)
  val add = Value
  /// Add with Carry (Rd := Rn + shifter_operand + carry flag)
  val adc = Value
  /// Subtract with Carry (Rd := Rn - shifter_operand - NOT(carry flag))
  val sbc = Value
  /// Reverse subtract with Carry (Rd := shifter_operand - Rn - NOT(carry flag))
  val rsc = Value
  /// Test (update flags after (Rn AND shifter_operand))
  val tst = Value
  /// Test Equivalence (update flags after (Rn XOR shifter_operand))
  val teq = Value
  /// Compare (update flags after (Rn - shifter_operand))
  val cmp = Value
  /// Compare Negated (update flags after (Rn + shifter_operand))
  val cmn = Value
  /// Logical OR (Rd := Rn OR shifter_operand)
  val orr = Value
  /// Move (Rd := shifter_operand)
  val mov = Value
  /// Bit Clear (Rd := Rn AND NOT shifter_operand)
  val bic = Value
  /// Move Not (Rd := NOT shifter_operand)
  val mvn = Value
}

class Alu extends Module {
  val io = IO(new Bundle {
    /// Opcode
    val opcode = Input(AluOpcode())

    /// Operand A
    val a = Input(UInt(32.W))
    /// Operand B
    val b = Input(UInt(32.W))
    /// Flags in
    val flagIn = Input(new ConditionFlags)
    /// Shifter carry
    val shifterCarry = Input(Bool())

    /// Output
    val out = Output(UInt(32.W))
    /// Flags out
    val flagOut = Output(new ConditionFlags)
  })

  import AluOpcode._
  val op = io.opcode

  // ---- Single shared adder for all arithmetic ops (carry-select style) ----
  // Every arithmetic op is mapped onto one 33-bit add of the form
  //   sum = opA + opB + carryIn
  // by pre-selecting/inverting operands and choosing the carry-in. The adder's
  // carry-out (sum bit 32) is the ARM C flag for *both* add and subtract: a
  // subtract a-b is computed as a + ~b + 1, whose carry-out is NOT(borrow) = C.
  // This replaces the previous per-opcode +&/-& chains (multiple inferred adders
  // + a wide result mux) with one adder feeding a shallow final mux.
  val isAdd  = (op === add) || (op === cmn)
  val isAdc  = op === adc
  val isSub  = (op === sub) || (op === cmp)
  val isSbc  = op === sbc
  val isRsb  = op === rsb
  val isRsc  = op === rsc
  val isArith = isAdd || isAdc || isSub || isSbc || isRsb || isRsc

  val swap     = isRsb || isRsc                       // reverse subtract: compute b - a
  val subtract = isSub || isSbc || isRsb || isRsc
  val opA      = Mux(swap, io.b, io.a)
  val opBraw   = Mux(swap, io.a, io.b)
  val opB      = Mux(subtract, (~opBraw).asUInt, opBraw)
  // carry-in: add/cmn -> 0 ; adc/sbc/rsc -> C ; sub/cmp/rsb -> 1
  val carryIn  = Mux(isAdc || isSbc || isRsc, io.flagIn.c,
                  Mux(isSub || isRsb, true.B, false.B))
  val sum      = (opA +& opB) +& carryIn.asUInt       // bit 32 = carry-out
  val arithOut = sum(31, 0)
  val arithC   = sum(32)

  // Overflow kept in the original per-class form (in terms of the raw a/b operands).
  val addV = !(io.a(31) ^ io.b(31)) && (io.a(31) ^ arithOut(31))   // add, adc, cmn
  val subV =  (io.a(31) ^ io.b(31)) && (io.a(31) ^ arithOut(31))   // sub, cmp, sbc
  val rsbV =  (io.a(31) ^ io.b(31)) && (io.b(31) ^ arithOut(31))   // rsb, rsc
  val arithV = Mux(isAdd || isAdc, addV, Mux(isRsb || isRsc, rsbV, subV))

  // ---- Logical / move results ----
  val logicOut = WireDefault(io.b)                    // mov default
  switch (op) {
    is (mvn)      { logicOut := (~io.b).asUInt }
    is (and, tst) { logicOut := io.a & io.b }
    is (eor, teq) { logicOut := io.a ^ io.b }
    is (orr)      { logicOut := io.a | io.b }
    is (bic)      { logicOut := io.a & (~io.b).asUInt }
  }

  io.out := Mux(isArith, arithOut, logicOut)

  io.flagOut.n := io.out(31)
  // Z is the 50 MHz-critical flag: reducing the 32-bit *muxed* io.out puts the
  // arith/logic result mux in series ahead of the 32-input zero-detect. Reduce each
  // candidate in parallel instead and mux the single Z bit, so the zero-detect starts
  // straight off the adder/logic output (the result mux is off this critical leg).
  io.flagOut.z := Mux(isArith, arithOut === 0.U, logicOut === 0.U)
  io.flagOut.c := Mux(isArith, arithC, io.shifterCarry)
  io.flagOut.v := Mux(isArith, arithV, io.flagIn.v)
}
