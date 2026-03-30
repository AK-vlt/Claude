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

                  +-------+
  xEnable -------| AND   |      +----------+          +---------+
                 |       |------|  TON     |          |   RS    |
                 |       |     | PT=T#1s  |   SET----|S       Q|---- xAlarmHeater
  xThermo  -NOT--|       |     |          |          |         |
  Contact        +-------+     | IN     Q |----------|         |
                               +----------+          |         |
                                                     |R1       |
  xAlarmReset ----+---+---+-------------------------|         |
                  |   |   |                          +---------+
                  +---+---+


  ================================================================
  СЕКЦИЯ 2: РАЗРЕШЕНИЕ РАБОТЫ
  ================================================================

                       +-------+
  xEnable ------------|       |
                      |       |
  xSystemRun ---------|       |
                      |  AND  |---- xRunPermit ---- xHeaterRunning
  xAlarmHeater -NOT---|       |
                      |       |
  xAlarmGeneral -NOT--|       |
                      |       |
  xThermoContact -----|       |
                       +-------+


  ================================================================
  СЕКЦИЯ 3: PID-РЕГУЛЯТОР (диапазон 0..100% !)
  ================================================================

                           +=====================+
                           |     PID_AT_F_1      |
                           |                     |
  xStageJust  ---NOT-------| xEnable             |
  Switched                 |                     |
                           |                     |
  rTempSupply  ------------| rPV            rPWR |----+--- rPID_Output
                           |                     |    |    (0..100%)
  rTempSetpoint -----------| rSP                 |    |
                           |                     |    |
  rKp  --------------------| rXp                 |    |
                           |                     |    |
  rTi  --------------------| rTi                 |    |
                           |                     |    |
  rTd  --------------------| rTd                 |    |
                           |                     |    |
  xATune  -----------------| xAT                 |    |
                           |                     |    |
  0.0  --------------------| rPWR_min            |    |
                           |                     |    |
  100.0  ------------------| rPWR_max            |    |
                           |   ВАЖНО: НЕ 300!    |    |
  0.0  --------------------| rPWR_off            |    |
                           |                     |    |
  rTempSetpoint -----------| rPV_0               |    |
                           +=====================+    |
                                                      |
                           +-------+                  |
  xManualMode  ---+-------| fSEL  |                  |
                  |       |  G    |--- rStage1_Duty   |
  rManualPower ---|-------|IN1    |    (0..100%)       |
                  |       |       |                    |
                  +-------|IN0    |--------------------+
                           +-------+


  ================================================================
  СЕКЦИЯ 4: КАСКАДНАЯ ЛОГИКА СТУПЕНЕЙ
  ================================================================

  --- 4.1 Таймер паузы (cooldown) после переключения ступени ---

                           +----------+
  xCooldownActive --------| TON      |
                          | PT=T#60s |
                          |          |
                          | IN     Q |----+
                          +----------+    |
                                          |
              +---------------------------+
              | Когда Q=TRUE:
              | xCooldownActive := FALSE
              +-----------------------------


  --- 4.2 Определение насыщения PID ---

      "PID упёрся в потолок"               "PID упёрся в пол"

                +------+                            +------+
  rPID_Output --| fGE  |                 rPID_Output| fLE  |
  98.0 ---------|      |                 2.0 -------|      |
                +--+---+                            +--+---+
                   |                                   |
                   |   +-------+                       |   +-------+
                   +---| AND   |                       +---| AND   |
                       |       |                           |       |
  xRunPermit ----------|       |        xRunPermit --------|       |
                       |       |                           |       |
  xManualMode ---NOT---|       |        xManualMode --NOT--|       |
                       |       |                           |       |
  xCooldown   ---NOT---|       |        xCooldown  --NOT---|       |
  Active               +---+---+        Active             +---+---+
                           |                                   |
                    +------+------+                     +------+------+
                    | TON         |                     | TON         |
                    | PT = T#30s  |                     | PT = T#30s  |
                    |             |                     |             |
                    | IN        Q |                     | IN        Q |
                    +------+------+                     +------+------+
                           |                                   |
                    +------+------+                     +------+------+
                    | R_TRIG      |                     | R_TRIG      |
                    |             |                     |             |
                    | CLK       Q |                     | CLK       Q |
                    +------+------+                     +------+------+
                           |                                   |
                           v                                   v
                    xStageUpEdge                        xStageDownEdge
                    (1 цикл!)                           (1 цикл!)


  --- 4.3 Набор ступеней (по фронту xStageUpEdge) ---

                    +-------+     +-------+
  xStageUpEdge ----| AND   |     | AND   |
                   |       |     |       |
  xStage2_On -NOT--|       |     |       |----> xStage3_On := TRUE
                   |       |     |       |      xStageJustSwitched := TRUE
                   +---+---+     |       |      xCooldownActive := TRUE
                       |         |       |
                       |    +----|       |
                       |    |    +-------+
                       v    |
              xStage2_On := TRUE          xStageUpEdge ----+
              xStageJustSwitched := TRUE                   |
              xCooldownActive := TRUE     xStage2_On ------+
                                          xStage3_On -NOT--+


  --- 4.4 Сброс ступеней (по фронту xStageDownEdge) ---

                      +-------+     +-------+
  xStageDownEdge ----| AND   |     | AND   |
                     |       |     |       |----> xStage2_On := FALSE
  xStage3_On -------|       |     |       |      xStageJustSwitched := TRUE
                     |       |     |       |      xCooldownActive := TRUE
                     +---+---+     |       |
                         |         |       |
                         |    +----|       |
                         |    |    +-------+
                         v    |
              xStage3_On := FALSE         xStageDownEdge ---+
              xStageJustSwitched := TRUE                    |
              xCooldownActive := TRUE     xStage3_On --NOT--+
                                          xStage2_On -------+


  ================================================================
  СЕКЦИЯ 5: ШИМ-ГЕНЕРАТОР ДЛЯ 1-Й СТУПЕНИ
  ================================================================

  Принцип: TON таймер с автосбросом создает пилообразный сигнал (ET).
  Сравниваем ET с расчётным временем включения -> дискретный ШИМ.

                  +============+
                  |  tonPWM    |
         +--NOT--| IN       Q |--+
         |       |            |  |
         +-------|  PT=T#10s  |<-+    (автосброс: IN := NOT Q)
                 |            |
                 |         ET |---+
                 +============+   |
                                  |
                                  |    +-------+
                                  +----| fLT   |
                                       |       |--- xStage1_DO
                          tDutyTime ---|       |    (дискретный выход)
                                       +-------+

  Расчёт tDutyTime:

  rStage1_Duty     +-------+     +-------+
  (0..100%)  ------| fDIV  |     | fMUL  |
  100.0  ----------|       |-----|       |--- tDutyTime
                   +-------+     |       |
                   tPWM_Period --|       |
                   (T#10s)       +-------+

  Пример: duty=60%, период=10с -> tDutyTime=6с
  ET: 0..1..2..3..4..5..6..7..8..9..10 -> сброс -> 0..
  DO:  1  1  1  1  1  1  0  0  0  0     -> 1  1 ...
                          ^6с
  Граничные случаи:
  - duty >= 100% -> xStage1_DO := TRUE  (постоянно ВКЛ)
  - duty <=   0% -> xStage1_DO := FALSE (постоянно ВЫКЛ)


  ================================================================
  СЕКЦИЯ 6: ФОРМИРОВАНИЕ ВЫХОДОВ
  ================================================================

                  +-------+
  xRunPermit ----| AND   |--- xStage1_DO (на дискретный выход)
                 |       |
  (ШИМ выход) ---|       |
                  +-------+

                  +-------+
  xRunPermit ----| AND   |--- xStage2_DO (на дискретный выход)
                 |       |
  xStage2_On  ---|       |
                  +-------+

                  +-------+
  xRunPermit ----| AND   |--- xStage3_DO (на дискретный выход)
                 |       |
  xStage3_On  ---|       |
                  +-------+


  ================================================================
  ВРЕМЕННАЯ ДИАГРАММА РАБОТЫ (пример нагрева от 15 до 24 C)
  ================================================================

  Уставка = 24 C

  Время ------->  0         30с        90с       150с      180с      270с
                  |          |          |          |         |         |
  Темп.прит:     15 --------+-- 17 ----+-- 20 ---+-- 23 ---+-- 25 --+-- 24
                             |          |         |         |         |
  PID выход:     |##100%####|##100%###|===60%===|==30%==|===0%====|==0%====
                             |          |         |         |         |
  1-я ступень:   |ШИМ 100%  |ШИМ 100% |ШИМ 60% |ШИМ 30%|  ВЫКЛ   |  ВЫКЛ
  (ШИМ)                      |          |         |         |         |
  2-я ступень:   |  ВЫКЛ    |== ВКЛ ==|== ВКЛ ==|== ВКЛ =|== ВКЛ ==|  ВЫКЛ
                             |          |         |         |         |
  3-я ступень:   |  ВЫКЛ    |  ВЫКЛ   |  ВЫКЛ  |  ВЫКЛ  |  ВЫКЛ   |  ВЫКЛ
                             |          |         |         |         |
  События:           PID=100%           PID<98%            PID=0%
                     30 сек            регулируем           30 сек
                        |                                      |
                        v                                      v
                   +Stage2 ON                            -Stage2 OFF
                   PID сброс                              PID сброс
                   Cooldown 60с                           Cooldown 60с


  ================================================================
  ПОЛНАЯ СТРУКТУРНАЯ СХЕМА (обзор)
  ================================================================

                +--------+     +-----+    +---------+
  Темп.прит -->| PID    |---->| ШИМ  |--->| Stage1  |---> DO1
  Уставка ---->| 0..100%|     | GEN  |    | (ШИМ)   |
                +---+----+     +------+    +---------+
                    |
                    |  >=98% 30с         +---------+
                    +------R_TRIG------->| Stage2  |---> DO2
                    |                    | (ВКЛ/   |
                    |                    |  ВЫКЛ)  |
                    |  >=98% 30с         +---------+
                    +------R_TRIG---+
                    |               |    +---------+
                    |               +--->| Stage3  |---> DO3
                    |  <=2% 30с          | (ВКЛ/   |
                    +------R_TRIG------->|  ВЫКЛ)  |
                                         +---------+

                    [Cooldown 60с между переключениями]
                    [R_TRIG - реакция только по фронту]
                    [PID сброс при каждом переключении]
*)
