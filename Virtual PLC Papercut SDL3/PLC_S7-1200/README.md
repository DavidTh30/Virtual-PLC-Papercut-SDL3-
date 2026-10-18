# Fluff Silo System — โปรแกรม PLC Siemens S7-1200 (SCL)

> สร้างจาก `Concept.txt` และ `SystemAnalysis.md`
> โปรแกรมนี้ทำงานตรงกับ Simulator (FluffSilo) ทุกเงื่อนไข
> ใช้ร่วมกับ **FluffSilo HMI** แบบ Siemens S7 ได้ทันที เพราะ `DB_HMI` ใช้ layout ตรงกับ Default S7 Map ของ HMI (DB10)

---

## 1. ไฟล์ทั้งหมด

| ไฟล์ | ชนิด | หน้าที่ |
|---|---|---|
| `01_PLC_Tags.xlsx` | PLC tag table | I/O ทั้งหมด (รูปแบบ import ของ TIA Portal, sheet "PLC Tags") |
| `01_PLC_Tags.csv` | PLC tag table | ข้อมูลเดียวกัน ใช้ copy/paste ลงตาราง tag ได้ |
| `02_UDT_typeDevStatus.scl` | UDT | 10 property ของอุปกรณ์ 1 ตัว (2 byte) |
| `03_DB_HMI.scl` | Global DB (**DB10**, non-optimized, retain) | ใช้แลกข้อมูลกับ HMI: สถานะ, คำสั่ง, Delay, Paddle Patterns |
| `04_FC_TenthsToTime.scl` | FC | แปลงค่า 0.1 s (Int) → TIME |
| `05_FC_ScaleAnalog.scl` | FC | แปลง analog 0..27648 → ค่าทางวิศวกรรม และตรวจสัญญาณผิดช่วง |
| `06_FC_ValidateParams.scl` | FC | จำกัดช่วงค่า Parameter ที่ HMI เขียนมา |
| `07_FC_LoadDefaults.scl` | FC | ใส่ค่าเริ่มต้นจาก Concept (7/3/3/3/5/5 s และ Pattern P1-P2-P3) |
| `08_FC_StepBlocked.scl` | FC | ตรวจว่า step ของ Pattern ถูก block หรือไม่ |
| `09_FB_Motor.scl` | FB | อุปกรณ์ 1 ตัว: 9 property + Priority L1..L6 + ตรวจ fault/feedback |
| `10_FB_Sequencer.scl` | FB | ลำดับ Auto Start / Auto Stop / Trip / E-Stop |
| `11_FB_PaddlePattern.scl` | FB | Paddle Patterns (สูงสุด 10 step) |
| `12_FB_FluffSilo.scl` | FB | โปรแกรมหลัก: เชื่อม I/O + ทุก FB + DB_HMI |
| `13_DB_iDB_FluffSilo.scl` | Instance DB | instance ของ FB_FluffSilo (ภายในมี multi-instance ทั้งหมด) |
| `14_OB1_Main.scl` | OB1 | เรียก `"iDB_FluffSilo"()` ทุก scan |
| `15_OB100_Startup.scl` | OB100 | ล้างคำสั่งค้าง และโหลดค่าเริ่มต้นเมื่อข้อมูล retain หาย |

---

## 2. Hardware

| รายการ | รุ่น (แนะนำ) | หมายเหตุ |
|---|---|---|
| CPU | **CPU 1214C DC/DC/RLY** (6ES7214-1HG40-0XB0), FW ≥ V4.2 | DI 14, DQ relay 10 (2 A), AI 2 (0-10 V) |
| Digital input module | **SM 1221 DI 8×24 VDC** (6ES7221-1BF32-0XB0) | ใส่ slot 2 → address เริ่มที่ I8.0 |
| Safety relay | เช่น 3SK1 | ตัดไฟ contactor ทั้งหมดโดย hardware และส่งสถานะเข้า I0.0 |
| Level sensor | 0-10 V = 0-100 % | ต่อเข้า AI0 ของ CPU (IW64) |

ถ้าใช้ CPU รุ่น DC/DC/DC ต้องมี relay คั่นก่อนเข้า coil ของ contactor
ถ้าใช้รุ่นหรือ slot อื่น ให้แก้แค่ address ใน tag table ไม่ต้องแก้โปรแกรม

---

## 3. I/O List

### Digital Inputs

| Address | Tag | ความหมาย | สถานะปกติ |
|---|---|---|---|
| %I0.0 | `EStop_OK` | Safety relay: วงจร E-Stop ปกติ | 1 = ปกติ (NC) |
| %I0.1 | `PB_AutoStart` | ปุ่ม Auto Start บนตู้ | NO |
| %I0.2 | `PB_AutoStop` | ปุ่ม Auto Stop บนตู้ | **NC** (0 = หยุด / สายขาดก็หยุด) |
| %I0.3 | `PB_Reset` | ปุ่ม Reset E-Stop และ Fault ทั้งหมด | NO |
| %I0.4 | `ExtRequest_In` | External Request จากเครื่องปลายทาง | 1 = ต้องการวัตถุดิบ |
| %I0.5 | `Blower01_FB` | Blower01 running feedback (aux contact ของ contactor) | NO |
| %I0.6 | `Blower01_OL` | Blower01 overload relay | NC (0 = trip) |
| %I0.7 | `Screw01_FB` | Screw01 running feedback | NO |
| %I1.0 | `Screw01_OL` | Screw01 overload | NC |
| %I1.1 | `Paddle01_FB` | Paddle01 running feedback | NO |
| %I1.2 | `Paddle01_OL` | Paddle01 overload | NC |
| %I1.3 | `Paddle02_FB` | Paddle02 running feedback | NO |
| %I1.4 | `Paddle02_OL` | Paddle02 overload | NC |
| %I1.5 | `Paddle03_FB` | Paddle03 running feedback | NO |
| %I8.0 | `Paddle03_OL` | Paddle03 overload (SM 1221) | NC |
| %I8.1–8.7 | — | สำรอง | |

### Digital Outputs

| Address | Tag | ความหมาย |
|---|---|---|
| %Q0.0 | `Blower01_Run` | Contactor K1 Blower01 |
| %Q0.1 | `Screw01_Run` | Contactor K2 Screw01 |
| %Q0.2 | `Paddle01_Run` | Contactor K3 Paddle01 |
| %Q0.3 | `Paddle02_Run` | Contactor K4 Paddle02 |
| %Q0.4 | `Paddle03_Run` | Contactor K5 Paddle03 |
| %Q0.5 | `Lamp_AutoRun` | ไฟเขียว: อยู่ในโหมด Auto Start |
| %Q0.6 | `Lamp_Fault` | ไฟแดง: มีอุปกรณ์ Fault หรือ level sensor ผิดปกติ |
| %Q0.7 | `Lamp_EStop` | ไฟเหลือง: E-Stop latched |
| %Q1.0 | `Fill_Request` | ขอเติมวัตถุดิบเข้าไซโล (level < 25 % → ON, ≥ 90 % → OFF) |
| %Q1.1 | — | สำรอง |

### Analog Input

| Address | Tag | ความหมาย |
|---|---|---|
| %IW64 | `Silo_Level_AI` | ระดับไซโล 0-10 V = 0-100 % |

> **External Request vs Fill_Request** — จากข้อสังเกตข้อ 14.1.1 ใน SystemAnalysis.md ผมแยกเป็น 2 สัญญาณ
> - `ExtRequest_In` (หรือปุ่ม External Request บน HMI) = ปลายทางขอวัตถุดิบ → สั่งให้ Screw และ Paddle ทำงาน ตาม Concept
> - `Fill_Request` = PLC ขอเติมวัตถุดิบเข้าไซโลตามระดับ (ตามโมเดลระดับใน Simulator)
>
> ถ้าความหมายจริงต่างจากนี้ ให้แก้ที่ REGION "Silo level and fill request" ใน FB_FluffSilo

---

## 4. โครงสร้างโปรแกรม

```
OB100 "Startup" ──► ล้างคำสั่ง HMI ที่ค้าง, FC_LoadDefaults (ถ้า retain หาย), FC_ValidateParams

OB1 "Main" ──► "iDB_FluffSilo"  (FB_FluffSilo)
                 ├─ E-Stop latch   (EStop_OK / HMI E-Stop → latch, Reset = PB_Reset / HMI)
                 ├─ External Request = ExtRequest_In OR DB_HMI.Cmd.ExtRequest
                 ├─ FC_ValidateParams, FC_TenthsToTime ×6
                 ├─ Seq      : FB_Sequencer      → Auto Start/Stop/Interlock ของแต่ละอุปกรณ์ + PatternCmd
                 ├─ Pattern  : FB_PaddlePattern   → PaddleCmd[0..2]  (ใช้ FC_StepBlocked)
                 ├─ Blower01, Screw01, Paddle01..03 : FB_Motor  → Run → %Q0.0..0.4
                 ├─ ไฟแสดงสถานะ, FC_ScaleAnalog → Silo level → Fill_Request
                 ├─ สถานะทั้งหมด → DB_HMI (Dev, Sys, Proc)
                 └─ ล้าง bit คำสั่ง pulse ของ HMI (รับคำสั่งครั้งเดียวต่อการกด)
```

### การเชื่อมระหว่าง Sequencer กับอุปกรณ์ (ตาม SystemAnalysis ข้อ 6.4)

| อุปกรณ์ | Auto Start (L1) | Auto Stop (L2) | Interlock (L2) |
|---|---|---|---|
| Blower01 | `Seq.BlowerAutoStart` | ไม่อยู่ Auto และ Blower ไม่ถูกสั่ง | — |
| Screw01 | `Seq.ScrewAutoStart` | ไม่อยู่ Auto | Blower01 ไม่ทำงาน (feedback) |
| Paddle0x | `Pattern.PaddleCmd[x]` | ไม่อยู่ Auto | Screw01 ไม่ทำงาน (feedback) |
| ทุกตัว | — | — | E-Stop (L6) = E-Stop latch |

### Priority ใน FB_Motor

```
Fault (L6) > E-Stop (L6) > Disable (L5) > Manual Stop (L4) > Manual Start (L3) > Auto Stop / Interlock (L2) > Auto Start (L1)
```

Fault ที่ FB_Motor ตรวจเอง จะค้าง (latch) จนกด Reset Fault และต้นเหตุหายแล้ว

| FaultCode | สาเหตุ |
|---|---|
| 1 | Overload relay trip (`_OL` = 0) |
| 2 | สั่ง Run แล้วไม่มี feedback ภายใน `FbTimeout` (3 s) หรือ feedback หายระหว่างวิ่ง |
| 3 | มี feedback ทั้งที่ไม่ได้สั่ง เกิน `FbTimeout` (contactor ติด) — reset ไม่ได้จนกว่า feedback จะหาย |

---

## 5. ตัวเลือก (Options)

แก้ค่าเริ่มต้นได้ใน `iDB_FluffSilo` หรือแก้ online ผ่าน Watch table

| ตัวแปร | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `FbTimeout` | T#3S | เวลารอ running feedback |
| `SafeInterlock` | FALSE | FALSE = Manual Start ชนะ Interlock (ตาม Concept) / **TRUE = Interlock ห้าม Manual Start ด้วย** (แนะนำสำหรับเครื่องจริง ตามข้อ 14.1.4) |
| `RestartAfterBlowerTrip` | TRUE | TRUE = เหมือน Simulator คือ Blower trip แล้ว reset จะวิ่งต่อเอง / **FALSE = Blower trip แล้วออกจาก Auto** ต้องกด Auto Start ใหม่ (ตามข้อ 14.1.3) |
| `FillOnLevel` / `FillOffLevel` | 25.0 / 90.0 % | ช่วง hysteresis ของ Fill_Request |

ค่า Delay และ Paddle Patterns อยู่ใน `DB_HMI` (retain) แก้ได้จาก HMI
ค่าเริ่มต้นตาม Concept จะถูกโหลดอัตโนมัติเมื่อ retain หาย

---

## 6. DB_HMI (DB10) — ใช้ร่วมกับ FluffSilo HMI

layout ของ `DB_HMI` ตรงกับ **Default S7 Map** ของ FluffSilo HMI ทุก byte (ดู `FluffSiloHMI/HMI_RegisterMap.md` หัวข้อ 3A)

| Offset | เนื้อหา | ทิศทาง |
|---|---|---|
| DBX0.0 – DBX9.7 | `Dev[0..4]` สถานะ 10 property ต่ออุปกรณ์ | PLC → HMI |
| DBX10.0 – 10.3 | `Sys`: AutoMode, ExtRequest, PatternActive, EStop | PLC → HMI |
| DBX12.0 – 12.4 | `Cmd`: AutoStart, AutoStop, EStop, ResetEStop (pulse), ExtRequest (คงค่า) | HMI → PLC |
| DBX14.0 – DBX18.5 | `DevCmd[อุปกรณ์×8 + คำสั่ง]` | HMI → PLC |
| DBW20 – DBW30 | `Delay[0..5]` (0.1 s) | HMI ↔ PLC |
| DBW32 / 34 / 36 | `Proc`: CurrentStep, StepElapsed (0.1 s), SiloLevel (0.1 %) | PLC → HMI |
| DBW40 | `Pattern.StepCount` | HMI ↔ PLC |
| DBW42 – DBW60 | `Pattern.Mask[0..9]` | HMI ↔ PLC |
| DBW62 – DBW80 | `Pattern.StepTime[0..9]` (0.1 s) | HMI ↔ PLC |

PLC จะล้าง bit คำสั่งแบบ pulse หลังทำงาน 1 scan ทำให้แต่ละคำสั่งทำงานครั้งเดียว
ถ้า HMI ค้างหรือหลุดระหว่างส่ง pulse ก็จะไม่มีคำสั่งค้างอยู่

---

## 7. การนำเข้า TIA Portal (V16 ขึ้นไป)

1. สร้างโปรเจกต์ → Add device → **CPU 1214C DC/DC/RLY** และใส่ **SM 1221 DI8** ที่ slot 2
   - ตรวจว่า address ของ SM คือ I8.0
   - ตรวจว่า AI0 ของ CPU ตั้งเป็น 0-10 V ที่ IW64
2. CPU Properties
   - **Protection & Security → Connection mechanisms → ติ๊ก "Permit access with PUT/GET communication from remote partner"** (จำเป็นสำหรับ FluffSilo HMI)
   - ตั้ง IP address ของ PROFINET interface
3. **PLC tags** → คลิกขวา *Import* → เลือก `01_PLC_Tags.xlsx`
   - หรือเปิด `01_PLC_Tags.csv` ใน Excel แล้ว copy คอลัมน์ Name / Data Type / Logical Address / Comment ไปวางในตาราง tag
4. **External source files** → *Add new external file* → เลือกไฟล์ `.scl` ทั้งหมด (02 – 15)
5. คลิกขวาที่ source ทีละไฟล์ **ตามลำดับเลข** → *Generate blocks from source*
   - ลำดับต้องเป็น UDT → DB_HMI → FC → FB → iDB → OB
   - OB1 "Main" ที่มีอยู่แล้วจะถูกแทนที่ (กดยืนยัน)
6. เปิด Properties ของ `DB_HMI`
   - ตั้ง **Number = 10** (เลือก manual numbering)
   - ตรวจว่า **Optimized block access = ปิด**
   - เปิด DB editor แล้วตรวจคอลัมน์ *Offset* ให้ตรงกับหัวข้อ 6
7. Compile (Software, rebuild all) → Download → RUN
8. ที่ FluffSilo HMI → Hardware Config
   - Protocol = **Siemens S7**
   - IP = IP ของ PLC, Port 102, Rack 0 / Slot 1
   - ใช้ Register map ค่าเริ่มต้น (DB10)
   - กด Test connection → Save → CONNECT

---

## 8. Checklist ทดสอบหน้างาน (Commissioning)

ตรวจโดยปลด power ของมอเตอร์ หรือใช้ Watch table + Force อย่างระมัดระวัง

| # | ทดสอบ | ผลที่ต้องได้ |
|---|---|---|
| 1 | กด E-Stop | ทุก contactor หลุด (hardware), `Lamp_EStop` ติด, HMI แสดง E-STOP ACTIVE |
| 2 | ปลด E-Stop แล้วกด Reset | ไฟ E-Stop ดับ, ระบบไม่สตาร์ทเอง |
| 3 | Auto Start | Blower01 วิ่ง, `Lamp_AutoRun` ติด |
| 4 | External Request ON ค้าง | หลัง Blower วิ่งครบ 7 s และ Request ค้างครบ 3 s → Screw01 วิ่ง → อีก 3 s Paddle Patterns เริ่มที่ Paddle01 |
| 5 | Pattern | P1 8 s → หยุด 2 s → P2 8 s → หยุด 2 s → P3 8 s → หยุด 2 s → วนซ้ำ |
| 6 | ปลด overload ของ Paddle ที่กำลังวิ่ง | Paddle นั้น Fault (แดง) และ Pattern ข้ามไป Paddle ถัดไปทันที |
| 7 | External Request OFF | Paddle หยุดทันที, Screw หยุดหลัง 3 s, Blower ยังวิ่ง |
| 8 | Screw01 overload ขณะ Auto | Paddle หยุดทันที, ออกจาก Auto, Blower หยุดหลัง 5 s |
| 9 | Auto Stop | Paddle และ Screw หยุดทันที, Blower หยุดหลัง 5 s, Request ไม่มีผล |
| 10 | ปลดสาย feedback ของมอเตอร์ที่วิ่งอยู่ | Fault code 2 หลัง 3 s |
| 11 | HMI: Manual Start / Stop / Disable / Enable / Reset Fault ทุกอุปกรณ์ | สี และ Level บน HMI ตรงตาม Concept |
| 12 | HMI: แก้ Delay และ Pattern แล้วปิด-เปิดไฟ PLC | ค่ายังอยู่ (retain) |

---

## 9. สิ่งที่ตรวจสอบแล้ว และสิ่งที่ยังไม่ได้ตรวจ

**ตรวจแล้ว**
- **Layout ของ DB_HMI**: คำนวณ offset ตามกฎ standard access ของ S7 (Bool เรียงเป็น bit, Int/Struct/Array เริ่มที่ byte คู่) แล้วเทียบกับ 119 address ของ HMI → ตรงทุกตัว, ขนาด 82 byte
- **ความครบของ symbol**: ทุก tag และ block ที่อ้างอิงใน SCL มีอยู่จริง, ทุก tag ใน tag table ถูกใช้งาน, ทุก block มี `END_` ครบคู่
- **Logic**: แปลง FB_Motor / FB_Sequencer / FB_PaddlePattern เป็น Python ทีละบรรทัด แล้วจำลองกับ contactor (มี feedback) → ผ่าน 31 scenario
  - ลำดับ Auto Start (เวลาวัดได้ 3.0 / 3.0 / 8.0 / 2.0 s)
  - Paddle fault แล้วข้ามไป Paddle ถัดไป
  - Request หาย, Screw trip (Blower หยุดหลัง 5 s), Auto Stop
  - Priority L3/L5/L6, E-Stop ห้าม Auto Start, Fault code 2 และ 3

**ยังไม่ได้ตรวจ**
- **ยังไม่ได้ compile ใน TIA Portal** (เครื่องนี้ไม่มี TIA) ถ้า compile แล้วเจอ error ให้ส่งข้อความ error มาเพื่อแก้
- จุดที่ TIA บางเวอร์ชันอาจเตือน: การเรียก function ซ้อนใน parameter, ชื่อ parameter ของ OB100 (`LostRetentive`, `LostRTC`)

---

## 10. ข้อควรระวังด้านความปลอดภัย

- E-Stop ต้องเป็นวงจร **hardware** (safety relay ตัดไฟ contactor) ตาม Risk assessment / PL ที่กำหนด PLC มาตรฐานไม่ใช่ safety PLC
- `iDB_FluffSilo` เป็น NON_RETAIN โดยตั้งใจ: เมื่อไฟดับแล้วกลับมา Auto mode, Manual Start และ Disable จะถูกล้าง ทำให้เครื่องไม่สตาร์ทเอง
- ก่อนใช้งานจริง ควรพิจารณาตั้ง `SafeInterlock = TRUE` และ `RestartAfterBlowerTrip = FALSE`
