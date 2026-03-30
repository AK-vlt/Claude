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
================================================================
СХЕМА FBD - ЭЛЕКТРОКАЛОРИФЕР С ШИМ-УПРАВЛЕНИЕМ
================================================================


================================================================
СЕКЦИЯ 1: АВАРИЯ КАЛОРИФЕРА
================================================================

  Блок AND1:
    Вход 1: xEnable
    Вход 2: NOT(xThermoContact)
    Выход:  -> на вход IN блока TON1

  Блок TON1:
    IN:  выход AND1
    PT:  T#1s
    Q:   -> на вход SET блока RS1

  Блок RS1:
    SET:    выход TON1.Q
    RESET1: xAlarmReset
    Q1:     -> xAlarmHeater

  Цепочка:

  xEnable -----+
               [AND1]---[TON1 PT=1s]---+
  NOT(xThermo) +                       |
                                      [RS1]--- xAlarmHeater
  xAlarmReset -------------------------+


================================================================
СЕКЦИЯ 2: РАЗРЕШЕНИЕ РАБОТЫ
================================================================

  Блок AND2 (5 входов):
    Вход 1: xEnable
    Вход 2: xSystemRun
    Вход 3: NOT(xAlarmHeater)
    Вход 4: NOT(xAlarmGeneral)
    Вход 5: xThermoContact
    Выход:  xRunPermit = xHeaterRunning

  xEnable ----------+
  xSystemRun -------+
  NOT(xAlarmHeater) +--[AND2]--- xRunPermit
  NOT(xAlarmGeneral)+
  xThermoContact ---+


================================================================
СЕКЦИЯ 3: PID-РЕГУЛЯТОР (0..100%)
================================================================

  Блок PID_AT_F_1:
    xEnable:  NOT(xStageJustSwitched)   <- сброс на 1 цикл!
    rPV:      rTempSupply
    rSP:      rTempSetpoint
    rXp:      rKp
    rTi:      rTi
    rTd:      rTd
    xAT:      xATune
    rPWR_min: 0.0
    rPWR_max: 100.0                     <- ВАЖНО: НЕ 300!
    rPWR_off: 0.0
    rPV_0:    rTempSetpoint
    Выход rPWR: -> rPID_Output (0..100%)

  Блок fSEL1 (выбор авто/ручной):
    G:   xManualMode
    IN0: rPID_Output        <- авто
    IN1: rManualPower       <- ручной
    Выход: rStage1_Duty (0..100%)

  NOT(xStageJust) --+
  rTempSupply ------+
  rTempSetpoint ----+
  rKp --------------+
  rTi --------------+--[PID_AT_F_1]--- rPID_Output
  rTd --------------+     rPWR_max=100!
  xATune -----------+
  0.0 (min) --------+
  100.0 (max) ------+
  0.0 (off) --------+
  rTempSetpoint ----+

  rPID_Output ---+
                [fSEL1 G=xManualMode]--- rStage1_Duty
  rManualPower --+


================================================================
СЕКЦИЯ 4: КАСКАДНАЯ ЛОГИКА СТУПЕНЕЙ
================================================================

--- 4.1 Cooldown (пауза после переключения) ---

  Блок TON_CD:
    IN: xCooldownActive
    PT: T#60s (tStageCooldown)
    Q:  когда TRUE -> xCooldownActive := FALSE

  xCooldownActive ---[TON_CD PT=60s]--- Q
                                        |
      когда Q=TRUE: xCooldownActive := FALSE (пауза кончилась)


--- 4.2 Детектор "PID упёрся ВВЕРХ" ---

  Блок fGE1:
    Вход 1: rPID_Output
    Вход 2: 98.0
    Выход:  rPID_Output >= 98.0

  Блок AND3 (4 входа):
    Вход 1: выход fGE1
    Вход 2: xRunPermit
    Вход 3: NOT(xManualMode)
    Вход 4: NOT(xCooldownActive)
    Выход:  -> на вход TON_UP

  Блок TON_UP:
    IN: выход AND3
    PT: T#30s (tStageUpDelay)
    Q:  -> на вход R_TRIG1

  Блок R_TRIG1:
    CLK: выход TON_UP.Q
    Q:   xStageUpEdge (TRUE ровно 1 цикл!)

  rPID_Output ---[fGE1 >=98]---+
  xRunPermit -------------------+
  NOT(xManualMode) ------------+--[AND3]---[TON_UP PT=30s]---[R_TRIG1]--- xStageUpEdge
  NOT(xCooldownActive) --------+


--- 4.3 Детектор "PID упёрся ВНИЗ" ---

  Блок fLE1:
    Вход 1: rPID_Output
    Вход 2: 2.0
    Выход:  rPID_Output <= 2.0

  Блок AND4 (4 входа):
    Вход 1: выход fLE1
    Вход 2: xRunPermit
    Вход 3: NOT(xManualMode)
    Вход 4: NOT(xCooldownActive)
    Выход:  -> на вход TON_DN

  Блок TON_DN:
    IN: выход AND4
    PT: T#30s (tStageDownDelay)
    Q:  -> на вход R_TRIG2

  Блок R_TRIG2:
    CLK: выход TON_DN.Q
    Q:   xStageDownEdge (TRUE ровно 1 цикл!)

  rPID_Output ---[fLE1 <=2]----+
  xRunPermit -------------------+
  NOT(xManualMode) ------------+--[AND4]---[TON_DN PT=30s]---[R_TRIG2]--- xStageDownEdge
  NOT(xCooldownActive) --------+


--- 4.4 Набор ступеней (по фронту xStageUpEdge) ---

  Приоритет: сначала 2-я, потом 3-я.

  Блок AND5 (включение 2-й ступени):
    Вход 1: xStageUpEdge
    Вход 2: NOT(xStage2_On)
    Выход:  -> xStage2_On := TRUE
              -> xStageJustSwitched := TRUE
              -> xCooldownActive := TRUE

  Блок AND6 (включение 3-й ступени):
    Вход 1: xStageUpEdge
    Вход 2: xStage2_On           <- 2-я уже горит
    Вход 3: NOT(xStage3_On)
    Выход:  -> xStage3_On := TRUE
              -> xStageJustSwitched := TRUE
              -> xCooldownActive := TRUE

  xStageUpEdge ----+
  NOT(xStage2_On) -+--[AND5]--- SET xStage2_On, сброс PID, cooldown

  xStageUpEdge ----+
  xStage2_On ------+--[AND6]--- SET xStage3_On, сброс PID, cooldown
  NOT(xStage3_On) -+


--- 4.5 Сброс ступеней (по фронту xStageDownEdge) ---

  Приоритет: сначала 3-я, потом 2-я.

  Блок AND7 (выключение 3-й ступени):
    Вход 1: xStageDownEdge
    Вход 2: xStage3_On
    Выход:  -> xStage3_On := FALSE
              -> xStageJustSwitched := TRUE
              -> xCooldownActive := TRUE

  Блок AND8 (выключение 2-й ступени):
    Вход 1: xStageDownEdge
    Вход 2: NOT(xStage3_On)      <- 3-я уже выключена
    Вход 3: xStage2_On
    Выход:  -> xStage2_On := FALSE
              -> xStageJustSwitched := TRUE
              -> xCooldownActive := TRUE

  xStageDownEdge -+
  xStage3_On -----+--[AND7]--- RESET xStage3_On, сброс PID, cooldown

  xStageDownEdge -+
  NOT(xStage3_On) +--[AND8]--- RESET xStage2_On, сброс PID, cooldown
  xStage2_On -----+


================================================================
СЕКЦИЯ 5: ШИМ-ГЕНЕРАТОР ДЛЯ 1-Й СТУПЕНИ
================================================================

  Блок TON_PWM (с автосбросом):
    IN: NOT(TON_PWM.Q)    <- когда досчитал, сбрасывается
    PT: tPWM_Period (T#10s)
    ET: текущее время (пила 0..10с..0..10с..)
    Q:  -> обратно на NOT -> IN

  Блок fDIV1:
    Вход 1: rStage1_Duty (0..100)
    Вход 2: 100.0
    Выход:  коэффициент (0.0 .. 1.0)

  Блок fMUL1:
    Вход 1: выход fDIV1
    Вход 2: tPWM_Period (T#10s)
    Выход:  tDutyTime (время вкл. в периоде)

  Блок fLT1 (компаратор):
    Вход 1: TON_PWM.ET
    Вход 2: tDutyTime
    Выход:  xStage1_DO (TRUE когда ET < tDutyTime)

       +----NOT----+
       |           |
       +--[TON_PWM PT=10s]
              |ET
              |
  rStage1_Duty --[fDIV1 /100]--[fMUL1 *10s]--- tDutyTime
              |                                    |
              +------------[fLT1]------------------+
                              |
                         xStage1_DO

  Граничные случаи:
    duty >= 100%  ->  xStage1_DO := TRUE  (постоянно ВКЛ)
    duty <=   0%  ->  xStage1_DO := FALSE (постоянно ВЫКЛ)

  Пример (duty=60%, период=10с, tDutyTime=6с):
    секунды:  0  1  2  3  4  5  6  7  8  9  10=сброс
    ET:       0  1  2  3  4  5  6  7  8  9  0
    ET<6с?:   да да да да да да нет нет нет нет да...
    DO выход: 1  1  1  1  1  1  0   0   0   0  1...


================================================================
СЕКЦИЯ 6: ФОРМИРОВАНИЕ ВЫХОДОВ
================================================================

  Блок AND_OUT1:  xRunPermit AND (ШИМ выход) = xStage1_DO
  Блок AND_OUT2:  xRunPermit AND xStage2_On  = xStage2_DO
  Блок AND_OUT3:  xRunPermit AND xStage3_On  = xStage3_DO

  (ШИМ) ------+--[AND_OUT1]--- xStage1_DO (дискретный выход)
  xRunPermit --+

  xStage2_On --+--[AND_OUT2]--- xStage2_DO (дискретный выход)
  xRunPermit --+

  xStage3_On --+--[AND_OUT3]--- xStage3_DO (дискретный выход)
  xRunPermit --+


================================================================
ВРЕМЕННАЯ ДИАГРАММА (нагрев 15C -> 24C)
================================================================

  Уставка = 24C

  Время:     0с       30с       90с      150с     180с     270с
             |         |         |         |        |        |
  Темп:     15C ------17C------20C------23C------25C------24C
             |         |         |         |        |        |
  PID:      100%      100%       60%       30%      0%       0%
             |         |         |         |        |        |
  Ст.1:    ШИМ100%   ШИМ100%   ШИМ60%   ШИМ30%   ВЫКЛ    ВЫКЛ
  Ст.2:    ВЫКЛ      ВКЛ       ВКЛ       ВКЛ      ВКЛ     ВЫКЛ
  Ст.3:    ВЫКЛ      ВЫКЛ      ВЫКЛ      ВЫКЛ     ВЫКЛ    ВЫКЛ
             |         |                            |        |
             |     PID=100%                     PID=0%       |
             |     30 сек                       30 сек       |
             |         |                            |        |
             |    +Stage2 ON                  -Stage2 OFF    |
             |    PID сброс                    PID сброс     |
             |    Cooldown 60с                 Cooldown 60с  |


================================================================
ОБЗОРНАЯ СХЕМА СИСТЕМЫ
================================================================

  Температура притока
         |
         v
  [PID 0..100%] ----> [ШИМ-генератор] ----> DO1 (1-я ступень)
         |
         |---[>=98% 30с]---[R_TRIG]----> SET/RESET ступеней
         |---[<=2%  30с]---[R_TRIG]-+
         |                          |
         |                          v
         |              DO2 (2-я ступень ВКЛ/ВЫКЛ)
         |              DO3 (3-я ступень ВКЛ/ВЫКЛ)
         |
         +--- При каждом переключении:
              1) PID сбрасывается (1 цикл)
              2) Cooldown 60с блокирует следующее переключение
              3) R_TRIG гарантирует 1 срабатывание
*)
