# SCL Compiler + SCL Studio (Lazarus / Free Pascal)

Compiler ภาษา **SCL** (Structured Control Language) ของ Siemens สำหรับ **S7-300 / S7-400 / S7-1200 / S7-1500**
แปลง source แบบ TIA Portal "External source" (`.scl`) + ตาราง tag (`.csv`) เป็นไฟล์ image **`.svpl`**
สำหรับโหลดลง **Virtual PLC** (สเปกอยู่ใน [docs/SVPL_Spec.md](docs/SVPL_Spec.md))

| ส่วน | ไฟล์ | หน้าที่ |
|---|---|---|
| **SCL Studio** (GUI) | `bin\SCLStudio.exe` | IDE: SCL editor, ตาราง Tag/Symbol, editor ของ UDT / DB / FB / FC / OB, All variables, All elements, Compile / Build |
| **sclc** (CLI) | `bin\sclc.exe` | compile จาก command line, dump image, รันชุดทดสอบบน reference Virtual PLC |

---

## 1. Build

ต้องมี Lazarus (ทดสอบกับ Lazarus 4.x + FPC 3.2.2 ที่ `C:\lazarus`)

```bat
build.bat        :: สร้าง bin\sclc.exe และ bin\SCLStudio.exe
run_tests.bat    :: compile ตัวอย่างทั้งหมด + รันชุดทดสอบ
```

หรือเปิด `gui\SCLStudio.lpi` ใน Lazarus IDE แล้วกด Run (package ที่ใช้: LCL, SynEdit)

---

## 2. SCL Studio

```
┌ Toolbar: New project | Open | Save all | New block | Tags | Compile | Build | Variables | Elements | CPU ▼ ┐
├──────────────────────┬────────────────────────────────────────────────────────────────────────────────┤
│ Project tree         │  แท็บ editor                                                                   │
│  FluffSilo [S7-1200] │   • SCL source (syntax highlight, undo/redo, find)                             │
│   PLC tags / Symbols │   • PLC tags / Symbols (grid)                                                  │
│   PLC data types     │   • Interface / members ของ UDT, DB, FB, FC, OB (grid ⇄ source)                │
│   Program blocks     │   • All variables / All elements (มี filter)                                   │
│    OB1 Main …        │   • Listing (bytecode + memory map)                                            │
│   Source files       ├────────────────────────────────────────────────────────────────────────────────┤
│                      │  Messages (ดับเบิลคลิก = ไปบรรทัดที่ผิด)                                         │
└──────────────────────┴────────────────────────────────────────────────────────────────────────────────┘
```

| งาน | วิธี |
|---|---|
| สร้างโปรเจกต์ | File > New project (สร้าง `.sclproj`, `PLC_Tags.csv`, `Main.scl`) |
| **Recent files** | File > *Recent projects* และ *Recent files* (อย่างละ 10 รายการ ล่าสุดอยู่บน, ไฟล์ที่หายมี "(missing)" และถามว่าจะลบออกไหม, *Clear list*). เปิด recent file ของโปรเจกต์อื่น → ถามว่าจะเปิดโปรเจกต์นั้นไหม. รายการเก็บที่ `%LOCALAPPDATA%\SCL Studio\sclstudio.ini` |
| เลือก CPU | combo **CPU** บน toolbar: S7-300 / S7-400 / S7-1200 / S7-1500 |
| เพิ่ม block | **New block** (Ctrl+N): OB / FB / FC / DB (global หรือ instance ของ FB) / UDT, กำหนดเลข block ได้ |
| แก้ SCL | ดับเบิลคลิก (หรือ Enter) ที่ block ใน tree |
| แก้ interface / member แบบตาราง | คลิกขวา block > *Edit interface / members* (หรือ Ctrl+Enter) → แก้ → **Apply to source** |
| Tag / Symbol | **Tags** (Ctrl+T): Name, Data type, Address (`%I0.0`, `%IW64`, `%MW10` …), Constant value, Comment |
| เลข block | คลิกขวา block > *Set block number…* (เช่น DB_HMI = 10) |
| ตรวจ | **Compile** (F7) — ใช้ข้อความใน editor ที่ยังไม่ save ได้ |
| สร้างไฟล์สำหรับ Virtual PLC | **Build** (F9) → `output\<project>.svpl`, `.lst`, `.map.txt` |
| **Find Declaration** | คลิกขวาที่ชื่อ > *Find Declaration* หรือ **Alt+Up** / **Ctrl+Click** — กระโดดไปยังจุดประกาศ (เลือกชื่อให้); ถ้าข้ามไฟล์ ไฟล์ปลายทางจะถูกเลือกใน Project tree (โฟลเดอร์ Source files เปิดให้อัตโนมัติ) |
| เปิด/ปิด Project tree | ปุ่ม **Project tree**, ปุ่ม `x` บนหัว panel, เมนู View หรือ **Alt+1** |
| **SCL elements** (panel ขวา) | ปุ่ม **SCL elements**, ปุ่ม `x`, เมนู View หรือ **Alt+2** — element ทั้งหมดแบ่งตามหมวด พับ/ขยายที่หัวข้อได้, ค้นหาได้, **ลากด้วยเมาส์ไปวางใน Editor** หรือดับเบิลคลิกเพื่อแทรกที่ cursor (cursor ไปอยู่ตำแหน่งที่ต้องเติมต่อ) |
| กลับตำแหน่งเดิม | คลิกขวา > *Go Back* หรือ **Alt+Left** (จำย้อนหลัง 100 ตำแหน่ง) |
| **Auto Highlight** | วาง cursor บนชื่อ → ทุกตำแหน่งที่ใช้ชื่อเดียวกันในไฟล์ถูกระบายสี (ไม่สนตัวพิมพ์เล็ก/ใหญ่, `#Seq` = `Seq` = `"Seq"`, ไม่ highlight keyword) |
| ดูตัวแปรทั้งหมด | **Variables** (F11): tag, ทุก DB (address แบบ `%DB10.DBW20`), interface ของทุก block |
| ดู element ทั้งหมด | **Elements** (F12): ชนิด, เลข, ไฟล์, access, ขนาด data/code, เรียกใช้ / ถูกเรียกโดย |

### หมวดใน SCL elements
Program control (IF, CASE, FOR, WHILE, REPEAT, REGION …) · Operators · Constants / literals · Elementary data types ·
Structured data types · Declaration sections · Block templates (FC/FB/OB/DB/UDT) · Bit logic / edges · Timers · Counters ·
Comparison / selection · Math · Conversion · Shift / rotate / slice · String ·
**Project:** PLC tags, Data blocks (instance DB = คำสั่งเรียกพร้อม input), Functions (FC = คำสั่งเรียกพร้อม parameter ครบ),
Function blocks (ประกาศ multi-instance / เรียกใช้), PLC data types — หมวด Project อัปเดตทุกครั้งที่ compile

### Find Declaration รองรับ
| ตำแหน่ง cursor | ไปที่ |
|---|---|
| `#local`, parameter, temp, constant, ชื่อ FC (RET_VAL) | บรรทัดประกาศใน block เดียวกัน |
| member ต่อกันหลายชั้น เช่น `#Seq.tmReqOn`, `#Paddle01.Available`, `"DB_HMI".Dev[0].Fault` | บรรทัดประกาศ member ในไฟล์ของ FB / UDT / DB นั้น |
| `"FC_x"`, `"FB_x"`, `"DB_x"`, `"UDT_x"` (ทั้งตอนเรียกใช้และในชนิดข้อมูล) | หัว block |
| `"PLC_Tag"` / user constant | ตาราง Tag แถวนั้น |
| ชื่อใน `BEGIN` ของ DB เช่น `Pattern.Mask[0]` | member ของ DB |
| `MAX`, `TON_TIME`, `#t.Q`, keyword | แสดงข้อความใน status bar (built-in / system / keyword) |

ทดสอบจาก command line ได้: `sclc project.sclproj --check --find-decl file.scl:line:col`

### โครงสร้างโปรเจกต์ (`.sclproj`, INI)
```ini
[Project]
Name=FluffSilo
CPU=S7-1200
OutputDir=output
[Sources]
File1=02_UDT_typeDevStatus.scl
...
[Tags]
File1=01_PLC_Tags.csv          ; Name;Path;Data Type;Logical Address;Comment[;Value]
[BlockNumbers]
DB_HMI=10                       ; ไม่ระบุ = กำหนดเลขอัตโนมัติ
[CyclicInterval]
Cyclic interrupt=100            ; ms สำหรับ OB30..38
```
Tag ที่ไม่มี address แต่มี `Value` = **user constant**

---

## 3. sclc (command line)

```bat
sclc project.sclproj [-o image.svpl] [-l listing.lst] [--check] [--cpu S7-1500]
sclc --import <folder> --cpu S7-1200 -p project.sclproj    :: สร้างโปรเจกต์จากโฟลเดอร์ .scl/.csv
sclc --dump image.svpl                                       :: แสดงเนื้อหา + disassembly
sclc --sim image.svpl --script test.txt                      :: รันบน reference Virtual PLC
```

ภาษา script ทดสอบ (`--sim`):
```
cycle-ms 10                          # เวลาต่อ cycle
set EStop_OK TRUE                    # เขียน tag / "DB".path
link Blower01_FB Blower01_Run        # input ตาม output ทุก cycle (จำลอง contactor feedback)
run 7s | run 500ms | run 3 cycles
expect "DB_HMI".Proc.CurrentStep 1   # PASS / FAIL
print "iDB_FluffSilo".Seq.AutoMode
echo ข้อความ
```

---

## 4. ภาษาที่รองรับ

| หมวด | รองรับ |
|---|---|
| Block | `TYPE` (UDT), `DATA_BLOCK` (STRUCT / VAR / instance ของ FB, UDT, system FB), `FUNCTION`, `FUNCTION_BLOCK`, `ORGANIZATION_BLOCK` |
| Header | `TITLE`, `VERSION`, `AUTHOR`, `FAMILY`, `{ S7_Optimized_Access := '...' }`, `RETAIN` / `NON_RETAIN`, `BEGIN` start values ของ DB |
| Section | `VAR_INPUT`, `VAR_OUTPUT`, `VAR_IN_OUT`, `VAR` (`RETAIN`/`NON_RETAIN`), `VAR_TEMP`, `VAR CONSTANT` |
| Data type | Bool, Byte, Word, DWord, LWord, SInt, Int, DInt, LInt, USInt, UInt, UDInt, ULInt, Real, LReal, Time, LTime, S5Time, Date, TOD, LTOD, DT, LDT, Char, WChar, String[n], WString[n], DTL, Array (หลายมิติ), Struct, UDT, multi-instance FB |
| Constant | `16#FF`, `2#1010`, `INT#5`, `W#16#7`, `T#1s500ms`, `LT#5ns`, `S5T#2s`, `D#2024-01-31`, `TOD#12:00:00`, `DT#…`, `'string'` (`$N $T $'` …), array init `[1, 2, 3(0)]` |
| Statement | `:=`, IF/ELSIF/ELSE, CASE (ค่า, `a..b`, ELSE), FOR (BY ลบได้), WHILE, REPEAT, EXIT, CONTINUE, RETURN, REGION |
| Operator | `OR XOR AND & = <> < <= > >= + - * / MOD ** NOT`, slice `.%X0 .%B1 .%W0 .%D0` |
| Call | FC (named / positional, `=>` output, InOut), FB multi-instance `#inst(...)`, single instance `"iDB"()`, system FB |
| System FB | TP, TON, TOF, TONR (+ `_TIME`, `_LTIME`, `IEC_TIMER.TON(...)`), CTU, CTD, CTUD (+ `_INT`, `_DINT`, `_UDINT`, `IEC_COUNTER`), R_TRIG, F_TRIG, RS, SR |
| Function | `X_TO_Y` (ทุกคู่ชนิดตัวเลข/บิต/เวลา), TRUNC, ROUND, CEIL, FLOOR, ABS, SQR, SQRT, EXP, LN, LOG, SIN…ATAN, FRAC, MIN, MAX, LIMIT, SEL, MUX, NORM_X, SCALE_X, SHL, SHR, ROL, ROR, LEN, CONCAT, LEFT, RIGHT, MID, FIND |
| Address | `%I0.0`, `%IW64`, `%QX0.1`, `%MW10`, `%DB10.DBX0.0` |

### กฎที่ตรวจตาม CPU
| | S7-300/400 | S7-1200 | S7-1500 |
|---|---|---|---|
| Optimized access | ไม่มี (เตือน) | ✓ | ✓ |
| SInt/USInt/UInt/UDInt, LReal, WString, DTL | ✗ | ✓ | ✓ |
| LInt/ULInt/LWord, LTime/LTOD/LDT, `*_LTIME` | ✗ | ✗ | ✓ |
| Slice `.%X0` | ✗ | ✓ | ✓ |
| Bit string ⇄ integer แบบ implicit | ✗ | ✓ | ✓ |
| OB อัตโนมัติ (เลข ≥ 123) | ✗ ต้องระบุเลข | ✓ | ✓ |

### ยังไม่รองรับ
`ANY` / `POINTER` / `VARIANT` / `REF_TO`, `Array[*]`, `AT` overlay, `GOTO`, ฟังก์ชันแปลง String (`INT_TO_STRING` …), S5 timer/counter (`T`/`Z`), system function ของ CPU (`RD_SYS_T`, `PEEK`, communication …), EN/ENO (ถูกละไว้)

---

## 5. โครงสร้างซอร์ส

```
core\scl_base.pas       ตำแหน่งในไฟล์, diagnostics, CPU family
core\scl_types.pas      ระบบชนิดข้อมูล, layout แบบ S7, system FB
core\scl_lexer.pas      lexer (typed constant, address, pragma, comment)
core\scl_ast.pas        AST
core\scl_parser.pas     recursive-descent parser
core\scl_project.pas    .sclproj, tag CSV, เลข block
core\scl_compiler.pas   semantic analysis + code generation + image
core\scl_declgen.pas    grid ⇄ source ของ interface, template block ใหม่
core\scl_navigate.pas   Find Declaration (หา identifier ใต้ cursor → ตำแหน่งประกาศ)
core\scl_vmformat.pas   รูปแบบไฟล์ .svpl, opcode, disassembler   ← ใช้ร่วมกับ Virtual PLC
core\scl_vmmem.pas      การเข้ารหัสค่าในหน่วยความจำ S7          ← ใช้ร่วมกับ Virtual PLC
core\scl_vm.pas         reference Virtual PLC (interpreter)     ← ต้นแบบของ Virtual PLC
cli\sclc.lpr            command line
gui\SCLStudio.lpi       IDE (sclide_main / sclide_editors / sclide_newblock / sclide_elements)
examples\FluffSilo      โปรเจกต์จริง (S7-1200) + tests\sequence.txt (65 checks)
examples\FeatureTest    ทดสอบ feature ของภาษา (S7-1500, 44 checks)
examples\ErrorTest      ทดสอบข้อความ error
docs\SVPL_Spec.md       สเปกไฟล์ image + instruction set สำหรับสร้าง Virtual PLC
```

ขั้นตอน compile: parse → ลงทะเบียน block → กำหนดเลข → tag → resolve type/layout → DB start image → code gen ต่อ block → สร้าง image

---

## 6. ผลการทดสอบ

| ชุด | ผล |
|---|---|
| FluffSilo (14 block, 25 tag) — commissioning checklist ใน README ของ PLC_S7-1200 | **65/65 PASS** |
| FeatureTest — CASE, WHILE, REPEAT, FOR BY -3, EXIT/CONTINUE, String, UDT array, multi-dim array, FC output/InOut, CTU, TP, IEC_TIMER, MUX, SHL/ROL, slice, Time, overflow, array init | **44/44 PASS** |
| ErrorTest — 10 error ที่ตั้งใจใส่ | ตรวจพบครบ 10 |
| DB_HMI layout เทียบกับ HMI register map (82 byte) | ตรงทุก offset |
| Round trip: grid → source ของทุก block ใน FluffSilo แล้ว compile + test ใหม่ | 65/65 PASS |

---

## 7. ขั้นต่อไป: Virtual PLC

1. ใช้ `scl_vmformat.pas` + `scl_vmmem.pas` โหลด `.svpl`
2. เริ่มจาก `scl_vm.pas` (interpreter ครบทุก opcode + system FB) แล้วเพิ่ม
   - cycle จริงตามเวลา, watchdog, OB121/OB122 แทน exception
   - เก็บ/คืนค่า retain ตาม `retainMap`
   - I/O driver (simulation, Modbus, OPC UA ฯลฯ) และ **S7 protocol (PUT/GET)** เพื่อให้ HMI ต่อ DB10 ได้
   - online monitor ด้วยตาราง `vars` และ `line table`
