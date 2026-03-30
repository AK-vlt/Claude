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
    iActiveStages       : INT;              (* Количество включенных базовых ступеней 0/1/2 *)
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

    (* Флаг для сброса интеграла PID при переключении ступени *)
    xResetPID           : BOOL;
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
END_IF;

(* ============================================================ *)
(*  3. PID-РЕГУЛЯТОР (всегда 0..100%)                            *)
(* ============================================================ *)

IF xRunPermit AND NOT xManualMode THEN
    fbPID(
        xEnable     := TRUE,
        rPV         := rTempSupply,
        rSP         := rTempSetpoint,
        rKp         := rKp,
        rTi         := rTi,
        rTd         := rTd,
        xAT         := xATune,
        rPWR_min    := 0.0,
        rPWR_max    := 100.0,              (* ВАЖНО: всегда 0..100% ! *)
        rPWR_off    := 0.0,
        rPV_0       := rTempSetpoint
    );
    rPID_Output := fbPID.rPWR;
ELSE
    fbPID(xEnable := FALSE);
    rPID_Output := 0.0;
END_IF;

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
   Определяем насыщение PID:
   - "Упёрся вверх" = PID >= 98% дольше tStageUpDelay
     Значит 1-я ступень на максимуме и не хватает -> добавить базу
   - "Упёрся вниз" = PID <= 2% дольше tStageDownDelay
     Значит 1-я ступень не нужна, база избыточна -> убрать базу
*)

tonSaturatedHigh(
    IN := (rPID_Output >= rHighThreshold) AND xRunPermit AND NOT xManualMode,
    PT := tStageUpDelay
);

tonSaturatedLow(
    IN := (rPID_Output <= rLowThreshold) AND xRunPermit AND NOT xManualMode,
    PT := tStageDownDelay
);

IF NOT xManualMode AND xRunPermit THEN

    (* === НАБОР СТУПЕНЕЙ (нагрев) === *)
    IF tonSaturatedHigh.Q THEN
        IF NOT xStage2_On THEN
            (* PID на 100% долго, 2-я ещё не горит -> ВКЛ 2-ю *)
            xStage2_On := TRUE;
            xResetPID := TRUE;
            (*
               После включения 2-й ступени доп. мощность пойдёт в контур,
               температура начнёт расти, PID сам снизит выход.
               1-я ступень начнёт ШИМить с меньшей скважностью.
            *)

        ELSIF NOT xStage3_On THEN
            (* 2-я уже горит, PID опять на 100% -> ВКЛ 3-ю *)
            xStage3_On := TRUE;
            xResetPID := TRUE;
        END_IF;
        (* Если все 3 ступени горят и PID на 100% - максимум, больше нечего добавлять *)
    END_IF;

    (* === СБРОС СТУПЕНЕЙ (остывание) === *)
    IF tonSaturatedLow.Q THEN
        IF xStage3_On THEN
            (* PID на 0% долго, 3-я горит -> ВЫКЛ 3-ю *)
            (* Мощности станет меньше, PID поднимет выход, 1-я начнёт ШИМить *)
            xStage3_On := FALSE;
            xResetPID := TRUE;

        ELSIF xStage2_On THEN
            (* 3-я уже выключена, PID на 0% -> ВЫКЛ 2-ю *)
            xStage2_On := FALSE;
            xResetPID := TRUE;
        END_IF;
    END_IF;

ELSIF xManualMode THEN
    (* Ручной режим - прямое управление ступенями *)
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
  │ PV ← Темп.прит. │
  │ SP ← Уставка    │
  │ PWR_min = 0      │
  │ PWR_max = 100    │◄── ВАЖНО! Не 300!
  │                  │
  │ rPWR ───────────────► rPID_Output (0..100%)
  └──────────────────┘

  БЛОК 3: ОПРЕДЕЛЕНИЕ НАСЫЩЕНИЯ
  ┌──────────┐    ┌─────┐
  │ PID >= 98├────┤ TON ├──► xSaturatedHigh (PID упёрся вверх)
  └──────────┘    │ 30с │
                  └─────┘
  ┌──────────┐    ┌─────┐
  │ PID <= 2 ├────┤ TON ├──► xSaturatedLow  (PID упёрся вниз)
  └──────────┘    │ 30с │
                  └─────┘

  БЛОК 4: КАСКАД СТУПЕНЕЙ (RS-триггеры)

  RS1 (2-я ступень):
    SET   = xSaturatedHigh AND NOT xStage2_On
    RESET = xSaturatedLow  AND NOT xStage3_On AND xStage2_On

  RS2 (3-я ступень):
    SET   = xSaturatedHigh AND xStage2_On AND NOT xStage3_On
    RESET = xSaturatedLow  AND xStage3_On

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
*)
