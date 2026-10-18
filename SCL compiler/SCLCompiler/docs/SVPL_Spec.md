# SVPL — Virtual PLC Image Format & Instruction Set (v1)

เอกสารนี้คือ **สเปกสำหรับสร้าง Virtual PLC** ที่จะโหลดไฟล์ `.svpl` ที่ SCL Compiler สร้างขึ้น

- ตัวอ่าน/เขียนไฟล์: `core/scl_vmformat.pas` (ไม่มี dependency กับ compiler — นำไปใช้ใน Virtual PLC ได้ทันที)
- การเข้ารหัสค่าในหน่วยความจำ: `core/scl_vmmem.pas`
- **Reference implementation** (ตัวตีความที่ทำงานได้จริง ใช้ทดสอบ compiler): `core/scl_vm.pas`
  ถ้าสเปกนี้กับ `scl_vm.pas` ขัดกัน ให้ถือ `scl_vm.pas` เป็นหลัก

---

## 1. ภาพรวม

```
 .scl + tags.csv ──► SCL Compiler ──► Project.svpl ──► Virtual PLC
                                      Project.lst      (load → cold start → cycle)
                                      Project.map.txt
```

Virtual PLC เป็น **stack machine**:

| ส่วน | รายละเอียด |
|---|---|
| Value stack | ช่องละ 8 byte: จำนวนเต็ม/บิต/เวลา เก็บเป็น `Int64`, Real/LReal เก็บเป็น `Double` |
| Memory areas | I, Q, M, DB (แยกตามเลข DB), L (local stack), C (constant pool, read only) |
| Address | `Int64` 1 ค่า ระบุ area + DB number + **bit offset** (ทุกการอ้างอิงเป็นหน่วย bit) |
| Byte order ในหน่วยความจำ PLC | **Big endian** เหมือน S7 (DB standard access ตรงกับ offset ของ TIA/HMI) |
| Byte order ของไฟล์ `.svpl` | Little endian |

---

## 2. Address encoding (Int64)

```
 bit 63    62..56     55..40        39..0
 [ 0 ][  area  ][  DB number  ][  bit offset  ]
```

| Area | ค่า | ความหมาย |
|---|---|---|
| `AREA_I` | 1 | Process image inputs (%I) |
| `AREA_Q` | 2 | Process image outputs (%Q) |
| `AREA_M` | 3 | Bit memory (%M) |
| `AREA_DB` | 4 | Data block — DB number อยู่ใน bit 40..55 |
| `AREA_L` | 5 | Local stack — bit offset เป็นตำแหน่ง **absolute** ภายใน L stack |
| `AREA_C` | 6 | Constant pool (string literal) — read only |
| `AREA_PI` / `AREA_PQ` | 7 / 8 | Peripheral I/O (`%IW64:P`) |

ตัวอย่าง: `%DB10.DBX12.3` = `MakeAddr(4, 10, 12*8+3)`

Bit numbering: bit 0 = LSB ของ byte (เหมือน S7: `%I0.0` = bit 0 ของ byte 0)

---

## 3. การเข้ารหัสค่าในหน่วยความจำ (VM type codes)

| Code | Type | ขนาด | ค่าบน stack | ในหน่วยความจำ (big endian) |
|---|---|---|---|---|
| 1 | Bool | 1 bit | 0/1 | 1 bit |
| 2 | Byte | 1 | unsigned | |
| 3 | Word | 2 | unsigned | |
| 4 | DWord | 4 | unsigned | |
| 5 | LWord | 8 | raw 64 bit | |
| 6 | SInt | 1 | signed | two's complement |
| 7 | Int | 2 | signed | |
| 8 | DInt | 4 | signed | |
| 9 | LInt | 8 | signed | |
| 10 | USInt | 1 | unsigned | |
| 11 | UInt | 2 | unsigned | |
| 12 | UDInt | 4 | unsigned | |
| 13 | ULInt | 8 | raw 64 bit | |
| 14 | Real | 4 | Double | IEEE-754 single |
| 15 | LReal | 8 | Double | IEEE-754 double |
| 16 | Time | 4 | ms (signed) | DInt ms |
| 17 | LTime | 8 | ns | LInt ns |
| 18 | S5Time | 2 | ms | BCD 3 หลัก + time base (bit 12-13: 10ms/100ms/1s/10s) |
| 19 | Date | 2 | วันนับจาก 1990-01-01 | UInt |
| 20 | Time_Of_Day | 4 | ms ตั้งแต่เที่ยงคืน | UDInt |
| 21 | LTime_Of_Day | 8 | ns ตั้งแต่เที่ยงคืน | ULInt |
| 22 | Date_And_Time | 8 | ms นับจาก 1990-01-01 | BCD 8 byte แบบ S7 (YY MM DD hh mm ss ms ms/weekday) |
| 23 | LDT | 8 | ns นับจาก 1970-01-01 | LInt |
| 24 | Char | 1 | code | |
| 25 | WChar | 2 | code | |
| 40 | Ptr | 8 | address (Int64) | raw 64 bit — ใช้กับ InOut / parameter แบบอ้างอิง |

**String[n]**: `[max n : byte][actual len : byte][chars...]` รวม n+2 byte
**WString[n]**: `[max : word][len : word][wchar ...]` รวม (n+2)*2 byte

### กฎ layout (เหมือน S7 standard access)
- Bool เรียงต่อกันเป็น bit
- Byte/Char/SInt/USInt เริ่มที่ byte ถัดไป
- ชนิดอื่นทั้งหมด, String, Array, Struct, instance ของ FB เริ่มที่ **byte คู่**
- ขนาด Struct ปัดเป็น byte คู่, Array of Bool เรียงเป็น bit
- InOut และ parameter แบบอ้างอิง ใช้ 8 byte (Ptr) เริ่มที่ byte คู่

Optimized block ใช้กฎเดียวกัน (offset ภายในไม่ต้องตรงกับ TIA เพราะไม่มีการเข้าถึงแบบ absolute)

---

## 4. โครงสร้างไฟล์ `.svpl`

```
Header (12 byte)
  char[4]  magic   = 'SVPL'
  u16      version = 1
  u8       cpu     0=S7-300 1=S7-400 2=S7-1200 3=S7-1500
  u8       reserved
  u32      section count
Directory (12 byte ต่อ section)
  char[4]  id
  u32      offset (จากต้นไฟล์)
  u32      size
Sections ...
```

`str` = `u32` offset ใน section `STRS` (UTF-8 ปิดท้ายด้วย 0) · `bytes` = `u32 length` + ข้อมูล

| Section | เนื้อหา |
|---|---|
| `META` | `str projectName`, `u32 n`, `str × n` (`Compiler=`, `CPU=`, `Created=`) |
| `BLKS` | code blocks (OB/FC/FB) — **index ในตารางนี้ = เลขที่ใช้ใน `opCall` / `opCallFB`** |
| `DATA` | data blocks พร้อม start values |
| `TAGS` | PLC tags (symbol table) |
| `CNST` | constant pool (`bytes`) → area C |
| `STRS` | string table |

### 4.1 BLKS
```
u32 count
ต่อ block:
  u8   kind          1=OB 2=FC 3=FB
  u8   flags         bit0 optimized
  u16  number        เช่น OB1, FB3
  str  name
  str  sourceFile
  u32  paramBytes    FC: ขนาด RET_VAL + parameters (caller จองให้)
  u32  tempBytes     ขนาด temp ที่ VM ต้องจองตอนเรียก (รวม temp ที่ compiler สร้าง)
  u32  instanceBytes FB: ขนาด instance
  u16  eventClass    OB: 1 program cycle, 10 time-of-day, 20 time delay, 30 cyclic interrupt,
                     40 hardware interrupt, 80.. error OBs, 100 startup, 121/122 error
  u16  reserved
  u32  interval      OB event 30: คาบเวลา ms
  bytes code         bytecode
  u32  lineCount     + (u32 codeOffset, u32 sourceLine) × lineCount   (สำหรับ debug/online)
  vars               ตารางตัวแปร (ดู 4.4) — offset relative กับ instance (FB) หรือ frame (FC/OB)
```

### 4.2 DATA
```
u32 count
ต่อ DB:
  u16  number
  u8   flags         bit0 optimized, bit1 มี retain, bit2 instance DB
  u8   reserved
  str  name
  str  instanceOf    ชื่อ FB / UDT / system FB หรือ ''
  bytes data         start values (S7 layout, big endian)
  bytes retainMap    1 bit ต่อ 1 byte ของ data (1 = retentive)
  vars
```

### 4.3 TAGS
```
u32 count
ต่อ tag: str name, str typeText, u8 area, u8 vmType, u16 reserved, i64 bitOffset, str comment
```

### 4.4 vars (ตารางตัวแปรสำหรับ online/monitor/HMI)
```
u32 count
ต่อรายการ: str path, str typeText, u8 vmType (0 = aggregate), u8 section, u8 flags, u8 reserved,
           i64 bitOffset, i64 sizeBits, str startValue, str comment
section: 1 Input 2 Output 3 InOut 4 Static 5 Temp 6 Return 7 Constant
flags:   1 retain, 2 by-ref (pointer), 4 hidden, 8 array, 16 struct
```
Array ≤ 256 element และ struct ถูกแตกเป็นรายการย่อย เช่น `Dev[0].AutoStart`, `Seq.tmReqOn.Q`

---

## 5. Execution model

### 5.1 Cold start (STOP → RUN)
1. สร้าง memory: I, Q, M = 0
2. ทุก DB: copy `data` จากไฟล์ (หรือคืนค่าส่วนที่ `retainMap` = 1 จากที่บันทึกไว้ ถ้าเป็น warm restart)
3. เรียก OB ทุกตัวที่ `eventClass = 100` (Startup) — ตัวแปร start-info ใน frame เช่น `LostRetentive`,
   `LostRTC` ให้ VM เขียนค่าตามสถานการณ์ (หาด้วยชื่อใน `vars` ของ OB)

### 5.2 Cycle
1. อ่าน input จริง → area I
2. เรียก OB ที่ `eventClass = 1` เรียงตามเลข OB (OB1 แล้ว OB123+)
3. เขียน area Q → output จริง
4. OB `eventClass = 30` เรียกทุก `interval` ms (ระหว่าง cycle)
5. เวลาของระบบ (สำหรับ timer) อ่านครั้งเดียวต่อการเรียก system FB

### 5.3 Call convention

**L stack** เป็น byte array เดียว ใช้ทั้ง frame ของ OB/FB/FC และ *pending frame* ของ FC

| ลงทะเบียน VM | ความหมาย |
|---|---|
| `FP` | byte offset ของ frame ปัจจุบันใน L |
| `Inst` | address ของ instance ปัจจุบัน (FB) |
| `LTop` | ส่วนบนสุดของ L ที่ใช้งาน |
| `Pending[]` | stack ของ base ของ FC frame ที่จองแล้วแต่ยังไม่เรียก |

**OB** — `FP = 0`, จอง `tempBytes` (ล้างเป็น 0), `Inst = 0`

**FC**
```
opFrameAlloc paramBytes      ; push LTop ลง Pending, จอง + ล้างเป็น 0
  ... เขียน parameter ด้วย opAddrNewFrame ofs / opStore ...
opCall idx                   ; base = Pending.top; LTop = base + paramBytes;
                             ; จอง tempBytes (ล้าง 0); FP = base; execute
                             ; หลัง return: LTop = base + paramBytes (temp ถูกปล่อย, parameter ยังอยู่)
  ... อ่าน output / RET_VAL ด้วย opAddrNewFrame ...
opFrameFree                  ; LTop = Pending.pop
```
FC frame layout: `[RET_VAL][Input][Output][InOut(Ptr)]` (= paramBytes) แล้วต่อด้วย temp ที่ offset `paramBytes`
Input/Output ที่เป็น Array/Struct/String ส่งเป็น Ptr

**FB**
```
... เขียน input ลง instance (address ของ instance + offset) ...
push instance address
opCallFB idx                 ; Inst = pop; FP = LTop; จอง tempBytes (ล้าง 0); execute; LTop = FP เดิม
... copy output ออกจาก instance ...
```
FB instance layout: `[Input][Output][InOut(Ptr)][Static]` (temp อยู่ใน frame ไม่อยู่ใน instance)
Multi-instance = instance ซ้อนอยู่ใน static ของ FB แม่, Single instance = DB ที่ `instanceOf` เป็น FB

Recursion ไม่อนุญาต (compiler ตรวจแล้ว)

---

## 6. Instruction set

รูปแบบ operand: `b`=u8 `w`=u16 `i`=i32 `u`=u32 `q`=i64 `f`=f64 (little endian, ต่อจาก opcode 1 byte)
Jump offset นับจาก **ต้นคำสั่งถัดไป**

| # | Opcode | Operand | Stack (ก่อน → หลัง) | ความหมาย |
|---|---|---|---|---|
| 0 | Nop | | | |
| 1 | PushI | q | → v | ค่าคงที่จำนวนเต็ม |
| 2 | PushF | f | → f | ค่าคงที่ Double |
| 3 | PushAddr | q | → a | address absolute |
| 4 | AddrInst | u bits | → a | `Inst + bits` |
| 5 | AddrLocal | u bits | → a | `L : FP*8 + bits` |
| 6 | AddrNewFrame | u bits | → a | `L : Pending.top*8 + bits` |
| 7 | AddrAdd | u bits | a → a' | บวก bit offset |
| 8 | AddrIndex | i lo, u stride, u count | a idx → a' | `a + (idx-lo)*stride`; idx นอกช่วง → **runtime error** (OB121 / STOP) |
| 9 | Load | b type | a → v | อ่านค่าตาม type |
| 10 | Store | b type | a v → | เขียน (Bool เขียน bit เดียว) |
| 11 | LoadPtr | | a → a' | อ่าน Ptr 8 byte ที่ a (0 = error) |
| 12 | MemCpy | u bits | dst src → | copy bit ต่อ bit (byte ต่อ byte ถ้า align) |
| 13 | StrCpy | b wide | dst src → | copy string ตัดตาม max length ของ dst |
| 14 | Dup | | v → v v | |
| 15 | Drop | | v → | |
| 16 | Swap | | a b → b a | |
| 17-23 | AddI SubI MulI DivI ModI NegI AbsI | | | Int64; Div/Mod ด้วย 0 → 0; Div ปัดเศษเข้าหา 0, Mod เครื่องหมายตามตัวตั้ง |
| 24-30 | AddF SubF MulF DivF NegF ExptF AbsF | | | Double |
| 31-34 | And Or Xor Not | | | bitwise 64 bit |
| 35-40 | EqI NeI LtI LeI GtI GeI | | a b → bool | signed |
| 41-44 | LtU LeU GtU GeU | | | unsigned 64 bit |
| 45-50 | EqF NeF LtF LeF GtF GeF | | | |
| 51 | Wrap | b type | v → v' | ตัด/ขยายเครื่องหมายให้ตรงกับความกว้างของ type (overflow แบบ S7) |
| 52 | I2F | | i → f | |
| 53 | U2F | | u → f | |
| 54-57 | F2ITrunc F2IRound F2IFloor F2ICeil | | f → i | Round = ปัดครึ่งไปเลขคู่ |
| 58 | F2F32 | | f → f | ปัดเป็น single precision (ใช้หลังคำนวณ Real) |
| 59 | GetBit | b n | v → bit | slice `.%Xn` |
| 60 | SetBit | b n | v bit → v' | |
| 61 | GetField | b shift, b width | v → f | slice `.%Bn .%Wn .%Dn` (B0 = byte ต่ำสุด) |
| 62 | SetField | b shift, b width | v f → v' | |
| 63-66 | Shl Shr Rol Ror | b width | v n → v' | ภายในความกว้าง `width` bit |
| 67-70 | MinI MaxI MinF MaxF | | a b → r | |
| 71 | Sel | | g in0 in1 → r | `g ? in1 : in0` |
| 72-74 | Jmp Jz Jnz | i rel | (Jz/Jnz pop 1) | |
| 75 | Call | w block | | เรียก FC (ดู 5.3) |
| 76 | CallFB | w block | a → | เรียก FB |
| 77 | FrameAlloc | u bytes | | |
| 78 | FrameFree | | | |
| 79 | Ret | | | กลับจาก block |
| 80 | Builtin | w id | f → f | 1 SQRT 2 EXP 3 LN 4 LOG 5 SIN 6 COS 7 TAN 8 ASIN 9 ACOS 10 ATAN 11 FRAC |
| 81 | SysFB | w id, b cntType | a → | system FB บน instance a (ดู 7) |
| 82 | StrCmp | b wide | a b → -1/0/1 | |
| 83 | StrLen | b wide | a → len | |
| 84 | StrConcat | b wide | dst a b → dst | |
| 85 | StrLeft | b wide | dst src n → dst | |
| 86 | StrRight | b wide | dst src n → dst | |
| 87 | StrMid | b wide | dst src l p → dst | |
| 88 | StrFind | b wide | a b → pos | |
| 89 | Trap | w code | | runtime error |
| 90 | MuxPick | b n | v0..v(n-1) k → vk | k นอกช่วง → 0 |

ค่าตัวเลขของ opcode = ลำดับใน `TOpcode` (`scl_vmformat.pas`)

ทุก block เริ่มด้วย `Jmp` ไปยัง prologue ท้าย block (กำหนด max length ของ String ใน temp) แล้ว `Jmp` กลับ

---

## 7. System function blocks (`opSysFB`)

| id | FB | id | FB |
|---|---|---|---|
| 1 | TP | 11 | TP_LTIME |
| 2 | TON | 12 | TON_LTIME |
| 3 | TOF | 13 | TOF_LTIME |
| 4 | TONR | 14 | TONR_LTIME |
| 20 | CTU | 30 | R_TRIG |
| 21 | CTD | 31 | F_TRIG |
| 22 | CTUD | 32 | RS |
| | | 33 | SR |

### Instance layout (bit offset จากต้น instance)

**Timer (Time)** — TP/TON/TOF/TONR, `*_TIME`, `IEC_TIMER` (22 byte)
| IN | R | PT | Q | ET | _ST (Byte) | _T0 (LInt) |
|---|---|---|---|---|---|---|
| 0 | 1 | 16 (Time) | 48 | 64 (Time) | 96 | 112 |

**Timer (LTime)** — `*_LTIME`, `IEC_LTIMER` (30 byte): IN 0, R 1, PT 16 (LTime), Q 80, ET 96 (LTime), _ST 160, _T0 176
`_ST` bit0 = IN ครั้งก่อน, bit1 = กำลังจับเวลา · `_T0` = เวลาเริ่ม (หน่วยเดียวกับ PT)

**Counter** — CTU/CTD/CTUD, `*_INT/_DINT/_UDINT`, `IEC_COUNTER`
| CU | CD | R | LD | Q | QU | QD | _CUO | _CDO | PV | CV |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 16 | 16 + bits(type) |
`cntType` (operand) บอกชนิดของ PV/CV

**R_TRIG / F_TRIG**: CLK 0, Q 1, _M 2 · **RS**: S 0, R1 1, Q1 2 · **SR**: S1 0, R 1, Q1 2

พฤติกรรมเป็นไปตาม IEC 61131-3 (ดูโค้ดใน `TVirtualPlc.SysFB`)

---

## 8. Runtime errors ที่ Virtual PLC ต้องจัดการ

| เหตุการณ์ | Reference VM | PLC จริง |
|---|---|---|
| Array index นอกช่วง (`AddrIndex`) | exception | เรียก OB121 หรือ STOP |
| `LoadPtr` ได้ 0 | exception | STOP |
| DB ไม่มีอยู่ | exception | OB122 / STOP |
| Value stack / L stack overflow | exception | STOP |
| หารจำนวนเต็มด้วย 0 | ได้ 0 | ENO = FALSE |

---

## 9. ตัวอย่าง

`#FC_TenthsToTime := DINT_TO_TIME(INT_TO_DINT(MAX(IN1 := #Tenths, IN2 := 0)) * 100);`

```
0  Jmp        -> 46        ; ไป prologue
5  AddrLocal  0.0          ; RET_VAL
10 AddrLocal  4.0          ; #Tenths
15 Load       Int
17 PushI      0
26 MaxI
27 Wrap       DInt
29 PushI      100
38 MulI
39 Wrap       DInt
41 Wrap       Time
43 Store      Time
45 Ret
46 Jmp        -> 5         ; prologue ว่าง (ไม่มี String temp)
```

ดูไฟล์ listing ทั้งหมดได้จาก `sclc project.sclproj -l out.lst` หรือเมนู View > Listing
