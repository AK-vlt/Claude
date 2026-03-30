(*
    Электрокалорифер с 3 ступенями и ШИМ-управлением

    КАСКАДНАЯ ЛОГИКА:
    PID всегда выдает 0..100% и управляет ТОЛЬКО 1-й ступенью через ШИМ.
    Ступени 2 и 3 - "база", включаются/выключаются при насыщении PID.

    Нагрев (набор ступеней):
    1) PID регулирует 1-ю ступень ШИМом (0..100%)
    2) Если PID упёрся в 100% и температура не достигнута ->
       ВКЛ 2-ю ступень, PID сбрасывается и снова регулирует 1-ю (0..100%)
    3) Если опять PID на 100% и не хватает ->
       ВКЛ 3-ю ступень, PID сбрасывается, 1-я снова ШИМит (0..100%)

    Остывание (сброс ступеней):
    1) PID упал до 0% и 3-я горит -> ВЫКЛ 3-ю, PID подскочит (1-я ШИМит)
    2) PID упал до 0% и 2-я горит -> ВЫКЛ 2-ю, PID подскочит (1-я ШИМит)
*)

FUNCTION_BLOCK FB_HeaterPWM
VAR_INPUT
    xEnable             : BOOL;             (* Включить калорифер *)
    xSystemRun          : BOOL;             (* Система работает *)
    rTempSupply         : REAL;             (* Температура притока, факт *)
    rTempSetpoint       : REAL;             (* Уставка притока *)
    rHysteresis         : REAL;             (* Гистерезис для защиты *)
    xThermoContact      : BOOL;             (* Термоконтакт (TRUE = норма) *)
    xAlarmReset         : BOOL;             (* Квитирование аварий *)
    xAlarmGeneral       : BOOL;             (* Общая авария *)

    (* Параметры PID *)
    rKp                 : REAL := 10.0;     (* Полоса пропорциональности *)
    rTi                 : REAL := 60.0;     (* Интегральная постоянная времени, с *)
    rTd                 : REAL := 0.0;      (* Дифференциальная постоянная времени, с *)
    xATune              : BOOL;             (* АНР - автонастройка *)

    (* Параметры ШИМ *)
    tPWM_Period         : TIME := T#10s;    (* Период ШИМ, рекомендуется 10-30с *)

    (* Задержки переключения ступеней *)
    tStageUpDelay       : TIME := T#30s;    (* Задержка перед добавлением ступени *)
    tStageDownDelay     : TIME := T#30s;    (* Задержка перед снятием ступени *)
    tStageCooldown      : TIME := T#60s;    (* Пауза после переключения ступени *)

    (* Ручное управление *)
    xManualMode         : BOOL;             (* Авто/Ручное (TRUE = ручное) *)
    rManualPower        : REAL;             (* Мощность 1-й ступени в ручном режиме *)
    xManualStage2       : BOOL;             (* Ручное включение 2-й ступени *)
    xManualStage3       : BOOL;             (* Ручное включение 3-й ступени *)
END_VAR

VAR_OUTPUT
    xStage1_DO          : BOOL;             (* Дискретный выход 1-й ступени (ШИМ) *)
    xStage2_DO          : BOOL;             (* Дискретный выход 2-й ступени *)
    xStage3_DO          : BOOL;             (* Дискретный выход 3-й ступени *)
    xHeaterRunning      : BOOL;             (* Нагреватель работает *)
    xAlarmHeater        : BOOL;             (* Авария калорифера *)
    rPowerStage1        : REAL;             (* Мощность 1-й ступени 0..100% для HMI *)
    iActiveStages       : INT;              (* Кол-во включенных базовых ступеней 0/1/2 *)
END_VAR

VAR
    (* PID регулятор - ВСЕГДА 0..100% *)
    fbPID               : PID;
    rPID_Output         : REAL;             (* Выход PID 0..100 *)

    (* Состояние базовых ступеней *)
    xStage2_On          : BOOL;             (* 2-я ступень зафиксирована *)
    xStage3_On          : BOOL;             (* 3-я ступень зафиксирована *)

    (* Таймеры определения насыщения PID *)
    tonSaturatedHigh    : TON;              (* PID на 100% дольше N секунд *)
    tonSaturatedLow     : TON;              (* PID на 0% дольше N секунд *)

    (* Детекторы фронтов - чтобы реагировать ОДИН РАЗ *)
    rtrigStageUp        : R_TRIG;           (* Фронт "пора добавить ступень" *)
    rtrigStageDown      : R_TRIG;           (* Фронт "пора убрать ступень" *)

    (* Таймер паузы после переключения ступени *)
    tonCooldown         : TON;              (* Блокировка повторного переключения *)
    xCooldownActive     : BOOL;             (* Пауза активна *)

    (* Пороги насыщения с небольшим допуском *)
    rHighThreshold      : REAL := 98.0;     (* Считаем "упёрся в потолок" *)
    rLowThreshold       : REAL := 2.0;      (* Считаем "упёрся в пол" *)

    (* ШИМ генератор *)
    tonPWM              : TON;
    tDutyTime           : TIME;
    rStage1_Duty        : REAL;

    (* Авария *)
    tonThermoDelay      : TON;
    rsAlarm             : RS;

    (* Разрешение работы *)
    xRunPermit          : BOOL;

    (* Сброс PID интеграла при переключении ступени *)
    xStageJustSwitched  : BOOL;             (* Флаг: ступень только что переключилась *)
END_VAR

(* ============================================================ *)
(*  1. АВАРИЯ КАЛОРИФЕРА                                         *)
(* ============================================================ *)

tonThermoDelay(
    IN := xEnable AND NOT xThermoContact,
    PT := T#1s
);

rsAlarm(
    SET    := tonThermoDelay.Q,
    RESET1 := xAlarmReset
);
xAlarmHeater := rsAlarm.Q1;

(* ============================================================ *)
(*  2. РАЗРЕШЕНИЕ РАБОТЫ                                         *)
(* ============================================================ *)

xRunPermit := xEnable
              AND xSystemRun
              AND NOT xAlarmHeater
              AND NOT xAlarmGeneral
              AND xThermoContact;

xHeaterRunning := xRunPermit;

(* При снятии разрешения - сброс всех ступеней *)
IF NOT xRunPermit THEN
    xStage2_On := FALSE;
    xStage3_On := FALSE;
    xCooldownActive := FALSE;
END_IF;

(* ============================================================ *)
(*  3. PID-РЕГУЛЯТОР (всегда 0..100%)                            *)
(* ============================================================ *)

(*
   ВАЖНО: после переключения ступени нужно сбросить PID,
   иначе интеграл остаётся "накрученным" и PID не опустится.
   Сброс делаем через выключение/включение xEnable на 1 цикл.
*)

IF xRunPermit AND NOT xManualMode THEN
    fbPID(
        xEnable     := NOT xStageJustSwitched, (* Сброс на 1 цикл при переключении *)
        rPV         := rTempSupply,
        rSP         := rTempSetpoint,
        rKp         := rKp,
        rTi         := rTi,
        rTd         := rTd,
        xAT         := xATune,
        rPWR_min    := 0.0,
        rPWR_max    := 100.0,              (* ВАЖНО: всегда 0..100%! *)
        rPWR_off    := 0.0,
        rPV_0       := rTempSetpoint
    );
    rPID_Output := fbPID.rPWR;
ELSE
    fbPID(xEnable := FALSE);
    rPID_Output := 0.0;
END_IF;

(* Сброс флага переключения (действует только 1 цикл) *)
xStageJustSwitched := FALSE;

(* В ручном режиме - прямое задание мощности *)
IF xManualMode THEN
    rStage1_Duty := LIMIT(0.0, rManualPower, 100.0);
ELSE
    rStage1_Duty := rPID_Output;
END_IF;

(* ============================================================ *)
(*  4. КАСКАДНАЯ ЛОГИКА СТУПЕНЕЙ                                 *)
(* ============================================================ *)

(*
   ЗАЩИТА ОТ ДРЕБЕЗГА: после каждого переключения ступени
   включается таймер паузы (tStageCooldown, по умолч. 60с).
   Пока пауза активна - переключения заблокированы.
   Это даёт время PID и температуре стабилизироваться.
*)

tonCooldown(
    IN := xCooldownActive,
    PT := tStageCooldown
);
IF tonCooldown.Q THEN
    xCooldownActive := FALSE;               (* Пауза закончилась *)
END_IF;

(*
   Определяем насыщение PID:
   - "Упёрся вверх" = PID >= 98% дольше tStageUpDelay
   - "Упёрся вниз" = PID <= 2% дольше tStageDownDelay

   tonSaturatedHigh/Low сбрасываются когда:
   - PID вышел из зоны насыщения (IN стал FALSE)
   - Это автоматически происходит после переключения ступени,
     потому что PID сбрасывается и выходит из насыщения
*)

tonSaturatedHigh(
    IN := (rPID_Output >= rHighThreshold)
          AND xRunPermit
          AND NOT xManualMode
          AND NOT xCooldownActive,           (* Блокировка во время паузы *)
    PT := tStageUpDelay
);

tonSaturatedLow(
    IN := (rPID_Output <= rLowThreshold)
          AND xRunPermit
          AND NOT xManualMode
          AND NOT xCooldownActive,           (* Блокировка во время паузы *)
    PT := tStageDownDelay
);

(*
   ДЕТЕКТОРЫ ФРОНТОВ: реагируем только на момент срабатывания TON,
   а не на весь период пока Q = TRUE.
   Без этого: TON.Q стал TRUE -> цикл 1: ВКЛ ступень 2 ->
   цикл 2: Q всё ещё TRUE, ступень 2 уже горит -> ВКЛ ступень 3!
   С фронтом: реагируем только 1 раз.
*)

rtrigStageUp(CLK := tonSaturatedHigh.Q);
rtrigStageDown(CLK := tonSaturatedLow.Q);

IF NOT xManualMode AND xRunPermit THEN

    (* === НАБОР СТУПЕНЕЙ (нагрев) === *)
    IF rtrigStageUp.Q THEN                   (* Только по фронту! *)
        IF NOT xStage2_On THEN
            (* PID на 100% долго, 2-я ещё не горит -> ВКЛ 2-ю *)
            xStage2_On := TRUE;
            xStageJustSwitched := TRUE;      (* Сброс PID интеграла *)
            xCooldownActive := TRUE;         (* Запуск паузы стабилизации *)

        ELSIF NOT xStage3_On THEN
            (* 2-я уже горит, PID опять на 100% -> ВКЛ 3-ю *)
            xStage3_On := TRUE;
            xStageJustSwitched := TRUE;
            xCooldownActive := TRUE;
        END_IF;
    END_IF;

    (* === СБРОС СТУПЕНЕЙ (остывание) === *)
    IF rtrigStageDown.Q THEN                 (* Только по фронту! *)
        IF xStage3_On THEN
            (* PID на 0% долго, 3-я горит -> ВЫКЛ 3-ю *)
            xStage3_On := FALSE;
            xStageJustSwitched := TRUE;
            xCooldownActive := TRUE;

        ELSIF xStage2_On THEN
            (* 3-я уже выключена, PID на 0% -> ВЫКЛ 2-ю *)
            xStage2_On := FALSE;
            xStageJustSwitched := TRUE;
            xCooldownActive := TRUE;
        END_IF;
    END_IF;

ELSIF xManualMode THEN
    xStage2_On := xManualStage2;
    xStage3_On := xManualStage3;
END_IF;

(* Подсчёт активных базовых ступеней для HMI *)
iActiveStages := 0;
IF xStage2_On THEN iActiveStages := iActiveStages + 1; END_IF;
IF xStage3_On THEN iActiveStages := iActiveStages + 1; END_IF;

rPowerStage1 := rStage1_Duty;

(* ============================================================ *)
(*  5. ШИМ-ГЕНЕРАТОР ДЛЯ 1-Й СТУПЕНИ                           *)
(* ============================================================ *)

(*
   Преобразуем аналоговый выход PID (0..100%) в дискретный ШИМ:
   - Период ШИМ = tPWM_Period (например 10с)
   - Таймер циклически считает 0 -> tPWM_Period -> сброс -> 0 ...
   - duty = 60% -> 6с включено, 4с выключено

   В FBD:
   [TON] -> таймер с автосбросом (IN := NOT Q)
   [MUL] -> rStage1_Duty / 100.0 * tPWM_Period = tDutyTime
   [LT]  -> tonPWM.ET < tDutyTime = xStage1_DO
*)

tonPWM(
    IN := NOT tonPWM.Q,
    PT := tPWM_Period
);

tDutyTime := REAL_TO_TIME(rStage1_Duty / 100.0 * TIME_TO_REAL(tPWM_Period));

IF rStage1_Duty >= 100.0 THEN
    xStage1_DO := TRUE;                    (* 100% - постоянно вкл *)
ELSIF rStage1_Duty <= 0.0 THEN
    xStage1_DO := FALSE;                   (* 0% - постоянно выкл *)
ELSE
    xStage1_DO := (tonPWM.ET < tDutyTime); (* ШИМ *)
END_IF;

(* ============================================================ *)
(*  6. ФОРМИРОВАНИЕ ВЫХОДОВ                                      *)
(* ============================================================ *)

IF NOT xRunPermit THEN
    xStage1_DO := FALSE;
    xStage2_DO := FALSE;
    xStage3_DO := FALSE;
ELSE
    xStage2_DO := xStage2_On;
    xStage3_DO := xStage3_On;
END_IF;

END_FUNCTION_BLOCK


(*
  ============================================================
  ОПИСАНИЕ СХЕМЫ FBD (для перерисовки из ST)
  ============================================================

  БЛОК 1: АВАРИЯ
  ┌─────────┐     ┌────┐
  │ xEnable ├──┬──┤ AND├──┐  ┌─────┐    ┌────┐
  └─────────┘  │  └────┘  ├──┤ TON ├────┤ RS ├── xAlarmHeater
  ┌─────────┐  │          │  │ 1с  │  S │    │
  │ Термо-  ├─NOT─────────┘  └─────┘    │    │
  │ контакт │                            │    │
  └─────────┘                   Reset ───┤    │
  ┌─────────┐                            └────┘
  │ Квитир. ├────────────────────────────┘
  └─────────┘

  БЛОК 2: PID (0..100% !!!)
  ┌──────────────────┐
  │   PID_AT_F_1     │
  │                  │
  │ PV  ← Темп.прит.│
  │ SP  ← Уставка   │
  │ PWR_min = 0      │
  │ PWR_max = 100    │◄── ВАЖНО! Не 300!
  │ xEnable ← NOT    │
  │   xStageJustSwitch│ ◄── Сброс интеграла на 1 цикл
  │                  │
  │ rPWR ───────────────► rPID_Output (0..100%)
  └──────────────────┘

  БЛОК 3: ОПРЕДЕЛЕНИЕ НАСЫЩЕНИЯ + ЗАЩИТА ОТ ДРЕБЕЗГА

  ┌──────────┐                           ┌─────┐   ┌───────┐
  │ PID >= 98├──┐                        │ TON ├───┤ R_TRIG├──► xStageUpEdge
  └──────────┘  │  ┌────┐               │ 30с │   └───────┘
  ┌──────────┐  ├──┤ AND├───────────────►│     │
  │NOT Cooldo├──┘  └────┘               └─────┘
  │  wnActive│
  └──────────┘
                                         ┌─────┐   ┌───────┐
  ┌──────────┐  ┌────┐                  │ TON ├───┤ R_TRIG├──► xStageDownEdge
  │ PID <= 2 ├──┤ AND├──────────────────►│ 30с │   └───────┘
  └──────────┘  └────┘                  └─────┘
                  ▲
  ┌──────────┐    │
  │NOT Cooldo├────┘
  │  wnActive│
  └──────────┘

  ┌─────┐
  │ TON ├── Cooldown (60с после каждого переключения)
  │ 60с │
  └─────┘

  БЛОК 4: КАСКАД СТУПЕНЕЙ

  По фронту xStageUpEdge:
    Если НЕ Stage2 -> ВКЛ Stage2, сброс PID, старт cooldown
    Иначе если НЕ Stage3 -> ВКЛ Stage3, сброс PID, старт cooldown

  По фронту xStageDownEdge:
    Если Stage3 -> ВЫКЛ Stage3, сброс PID, старт cooldown
    Иначе если Stage2 -> ВЫКЛ Stage2, сброс PID, старт cooldown

  БЛОК 5: ШИМ-ГЕНЕРАТОР
  ┌─────┐
  │ TON ├──┐  (автосброс: IN := NOT Q)
  │ 10с │  │
  └──┬──┘  │
     │ET   │
     ▼     │
  ┌──────────────┐
  │ ET < DutyTime├──► xStage1_DO (дискретный выход)
  └──────────────┘
     ▲
  ┌──────────────────────┐
  │ DutyTime =           │
  │ PID_Output/100 * 10с │
  └──────────────────────┘

  ============================================================
  ВРЕМЕННАЯ ДИАГРАММА РАБОТЫ (пример)
  ============================================================

  Время -->
  Темп:     15°C ─────────── 18°C ──── 20°C ── 22°C ── 24°C(уставка) ── 26°C(перегрев)
  PID:      |▓▓▓▓▓100%▓▓▓▓▓|▓▓▓100%▓▓|░░60%░░|░30%░|░░0%░░░░░|░0%░░░░░|
  Stage1:   |ШИМ 100%(вкл)  |ШИМ 100% |ШИМ 60%|ШИМ30|  ВЫКЛ   |  ВЫКЛ  |
  Stage2:   |     ВЫКЛ      |   ВКЛ   |  ВКЛ  | ВКЛ |  ВКЛ    |  ВЫКЛ  |
  Stage3:   |     ВЫКЛ      |   ВЫКЛ  |  ВЫКЛ | ВЫКЛ|  ВЫКЛ   |  ВЫКЛ  |
                             ▲                                    ▲
                         PID=100% 30с                         PID=0% 30с
                         -> Stage2 ON                         -> Stage2 OFF
                         -> PID сброс                         -> PID сброс
                         -> cooldown 60с                      -> cooldown 60с
*)
