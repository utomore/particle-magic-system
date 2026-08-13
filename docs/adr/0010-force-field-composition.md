# ADR-0010：力場層落地——組合點語意、穩定粒子身分、熱重載狀態政策

- 狀態：已採納（2026-08-13）
- 相關：[ADR-0001](0001-hybrid-particle-model.md)（本 ADR 補齊其自承的缺口）、[ADR-0003](0003-fixed-role-slots.md)（符文歸屬論證）、[architecture.md §3.2/§4.6/§7/§8.3](../architecture.md)、[func-spec 0007](../func-spec/0007-force-field-layer.md)（實作載體）

## 背景

ADR-0001 核准了「解析為主、可選力場層」的混合粒子模型，但在後果一節明文承認：「兩層模型的組合點語意需要清楚定義」——這個缺口懸置至今。力場層是系統**第一個跨幀狀態**，其設計直接觸碰三條既有公理：確定性/重播契約（ADR-0001）、固定時步（architecture §11）、熱重載＝重新施法（architecture §8.3）。本 ADR 在 func-spec 0007 動工前把全部語意決策釘死。

核心技術難題：解析層是 `t` 的無狀態純函數，粒子依 `Envelope` 排程**循環重生**，且每幀輸出的 `ParticleBuffer` 長度會變（死亡粒子被濾除、row 會位移）；力場層卻要跨幀累積位移。兩者的身分對應與組合點若定義錯誤，會產生粒子重生瞬間瞬移（teleport）或狀態串位（同一格狀態被不同粒子輪流使用）的 bug。

## 決策

**D1｜組合語意＝相加式位移覆蓋＋半隱式尤拉積分（使用者裁決 2026-08-13）**
`renderedPos = analyticPos(t) + fieldDisplacement`。每個穩定槽位存 `(velocity, displacement)`；每個固定步：`accel = Σ fieldAccel(f, analyticPos + disp)`、`vel' = vel + accel·dt`、`disp' = disp + vel'·dt`（symplectic/半隱式尤拉）。已知限制（明文記錄，非 bug）：長時間大 dt 下渦流/吸引子的能量會漂移；本模型不是精確軌道力學。

**D2｜FieldState 以穩定槽位 `(emitterIndex, particleIndex)` 為鍵，絕非 buffer row**
槽位數＝各 emitter 的 `emCount`，編譯期固定、永不搬動。每幀 buffer 的 row 順序是這個穩定身分空間的確定性子集列舉（存活過濾），疊加時以同一列舉函數對齊——單一事實來源，禁止兩份列舉邏輯並存。

**D3｜重生偵測＝年齡單調性破壞；死亡/未出生＝歸零靜止態**
每槽位存 `lastAge`；新一步若 `age < lastAge`（或槽位先前無狀態），視為新世代，丟棄舊 velocity/displacement、從靜止態重新積分；`particleAge` 回傳 `Nothing`（死亡或未出生）時槽位歸零。保證重生瞬間 `disp = 0`，畫面位置與解析層重生位置完全重合——**結構性不可能 teleport**。不新增世代欄位到 `Envelope`（0002 凍結排程語意零觸碰）。

**D4｜符文歸屬：`ForceField` 掛 `Circle` 頂層 `circleFields`，不佔任何符文槽**
理由：(1) ADR-0003 槽位符文的共同不變量是「純函數 of t、每幀重求值」，力場的跨幀狀態會在此心智模型上開例外；(2) 解釋器 fold 的 by-slot override 語意（同類後蓋前）不適合表達「多場疊加」（`step` 吃列表，不是覆寫鏈）；(3) 內圈 2 槽/夾層 1 槽稀缺，場搶槽位會與既有符文互斥得不自然；(4) 0006 的 `circlePhases` 已立「陣的整體屬性掛頂層」先例，力場＝「陣的物理環境」，同構。

**D5｜v1 範圍：三種場、靜態參數、世界座標、僅場對粒子**
`Gravity`（常數加速度向量）、`PointAttractor`（center/strength/softening，正吸負斥，softening 防奇異點）、`Vortex`（center/axis/切向 strength/radial falloff）。無 Expr 時變參數、無施法者相對座標系；「僅場對粒子」沿 architecture §7 既定，粒子對粒子明確非目標。

**D6｜相位互動：力場只作用於 `emPhase == Casting` 的發射器（使用者裁決 2026-08-13）**
陣形（Drawing）粒子的視覺目的是精確呈現魔法陣幾何，被場扭曲會破壞可讀性，且省下陣形粒子的每步積分成本。無 phases 的陣只有一個 `emPhase = Casting` 發射器（0006 凍結），此規則自動退化為 no-op。

**D7｜決定論/重播契約延續**
`FieldState` 每步轉移是 `(fields, dt, 各槽位 age+basePos)` 的純函數；basePos 來自既有確定性解析層；無 wall-clock。同 `(Circle, CastContext, dt 序列)` ⇒ 逐位元相同的 `FieldState` 與 `FrameOutput` 序列。

**D8｜熱重載狀態政策：重載＝重新施法＝FieldState 歸零，不遷移**
architecture §8.3 的 POC 政策此前只是預告（無狀態可歸零），本 ADR 對力場層明文釘死。編輯中 morphing／狀態遷移規則留給未來 spec。

**D9｜零場相容律**
`circleFields = []` 時 `advanceSpell`/`observeSpell` **結構性跳過**全部力場計算（分支跳過，非算出恆等值），保證：(a) 與 0007 之前逐位元相同行為；(b) 零額外成本。比照 0006「castStart = 0 直接跳過位移」的先例手法。

## 後果

**正面**：

- 身分模型清楚：`(emitter, index)` 是編譯期常量空間，未來效能 spec 把 `FieldState` SoA 化只換容器、不碰組合語意。
- 速度積分讓場「看起來像場」（拋物線、軌道彎曲的連續手感）。
- `App.Loop` 零改動：0005 交付的 `advanceSpell ×n／observeSpell ×1` 迴圈天然就是「每固定步積分、每幀觀測」的正確載體。

**負面**：

- 帶場的 spell 每個**固定步**（非每幀）都要對存活槽位重算解析基準位置——成本上限受 `Magic.Step.plan` 的 maxSteps clamp 保護，但仍是新的熱路徑（效能 spec 的量測對象）。
- 半隱式尤拉的能量漂移在極端參數下可見（記錄為已知限制）。
- 陣形粒子「感覺不到場」——若玩家預期整個陣被風吹歪，v1 明文不支援（D6）。

## 被否決的替代方案

- **純位移覆蓋（無速度狀態）**：手感弱（重力無拋物線、彈道連續性表達不了）。記錄為**可退回備案**：velocity 是純內部狀態，退回不動 JSON schema 與對外介面。
- **Verlet／RK4 積分器**：對「僅場對粒子」的 POC 是不必要的複雜度。
- **FieldState 以 buffer row 為鍵**：變長 buffer 的 row 位移正是要避免的狀態串位 bug 本身。
- **場掛 `InnerRune`/`BridgeRune` 槽位**：見 D4 四點理由。
- **施法者座標系相對的場**：v1 非目標，留後續 spec（不影響本 ADR 的組合語意）。
- **場作用於全部相位（含 Drawing/Converging）**：陣形可讀性與積分成本理由否決（D6）。
