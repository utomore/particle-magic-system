---
id: B001
type: bugfix
title: step-plan-ratio-overflow
description: 時步規劃器比值溢位導致積壓爆表時反而回 0 步
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: []
related-feature: []
---

# B001: 時步規劃器的比值溢位

## 症狀

`src/boundary/Magic/Step.hs` 的 `plan :: Double -> Int -> Double -> Double -> StepPlan`,在**四個輸入全是有限值**的情況下,會回傳與模組語意完全相反的計畫。

模組註解與 [particle-simulation/design.md](../../particle-simulation/design.md) 的 C5 都寫明:

> 積壓超過上限時**截斷並丟棄餘額**:模擬變慢,而不是凍結。

實際行為是**凍結**——積壓越大,跑的步數越少,最後歸零:

| 輸入 `plan dt maxSteps elapsed acc` | 期望 | 實際 |
|---|---|---|
| `plan 1e-300 8 1e300 0` | `StepPlan 8 0` | `StepPlan 0 1.0e300` |
| `plan (1/60) 8 1e300 0` | `StepPlan 8 0` | `StepPlan 0 1.0e300` |
| `plan (1/60) 8 1e19 0` | `StepPlan 8 0` | `StepPlan (-8742554432415203328) 1.0145709240540254e19` |
| `plan (1/60) 8 1e308 1e308` | `StepPlan 8 0` | `StepPlan 0 Infinity` |

三種壞法,一個根因,嚴重度遞增:

1. **凍結且不可恢復**:回 `0` 步的同時把爆表的積壓原封不動交還給宿主,下一幀再算一次仍是 `0` 步——累加器永遠不會下降,模擬**永久停在原地**。截斷護欄本來就是為了活過這種積壓而存在的,結果它正好在該生效時失效。
2. **負步數**:`stepsToRun = -8742554432415203328` 會直接變成宿主的 `for (i = 0; i < steps; i++)` 迴圈界限或 `while (steps-- > 0)`——後者在 C 面就是一個近乎無窮的迴圈。
3. **累加器毒化**:`acc` 與 `elapsed` 各自有限但相加溢位成 `Infinity` 時,`accAfter` 也是 `Infinity`,之後每一幀都被毒化。

影響範圍:`Magic.Step.plan` 的三個消費者——demo 外殼 `app/App/Loop.hs`、C ABI 的 `pm_plan_steps`(`src/ffi/Magic/FFI.hs`,轉呼而非複製)、以及測試套件。C 面已擋掉非有限與負值輸入,但**本缺陷的輸入全數合法**(`dt > 0` 有限、`max_steps >= 0`、`elapsed` 有限、`acc >= 0` 有限),會原樣穿過 C 面的參數檢查。

## 重現步驟

```haskell
ghc -isrc/boundary -e 'print (plan 1e-300 8 1e300 0)' src/boundary/Magic/Step.hs
-- StepPlan {stepsToRun = 0, accAfter = 1.0e300}
```

回歸測試落在 `test/StepSpec.hs`(`Magic.Step.plan` 的既有測試模組,不新增 cabal 條目)。

## 根因分析

`src/boundary/Magic/Step.hs:38`:

```haskell
n = floor (acc' / dt + stepEpsilon)
 in if n > maxSteps
      then StepPlan maxSteps 0
      else StepPlan n (max 0 (acc' - fromIntegral n * dt))
```

截斷的判斷寫成「先 `floor` 成 `Int`,再比 `n > maxSteps`」。這一步預設 `acc' / dt` 落得進 `Int`,但那是**兩個有限 Double 相除**的結果,值域是整個 Double:

- `1e300 / 1e-300` 直接溢位成 `Infinity`;
- `1e300 / (1/60)` = `6e301`,有限,但遠超 `Int` 的 `2^63`;
- `acc + max 0 elapsed` 本身也可能在兩個有限加數下溢位成 `Infinity`。

`floor :: Double -> Int` 對這些值沒有任何飽和保護(GHC 9.14.1 實測:`floor (1/0 :: Double) :: Int == 0`、`floor (1e300 :: Double) :: Int == 0`、`6e20` 則得到大負數)。得到的 `n` 是無意義的位元組合,**`n > maxSteps` 這道護欄於是永遠不會觸發**,程式流進 `else` 分支,用同一個垃圾 `n` 去算 `acc' - n * dt`,結果就是「回 0 步、積壓原地不動」或「回負步數」。

換句話說:護欄本身寫對了,但它被放在一個**已經失去資訊的量**上。判斷「積壓超過 `maxSteps` 了嗎」不需要先把比值變成 `Int`——比值自己就能回答。

## 修復方向

把截斷的判斷從 `floor` 之後移到 `floor` **之前**,直接問比值:

```
ratio >= fromIntegral maxSteps + 1   ⟺   floor ratio > maxSteps
```

兩式對所有落在 `Int` 值域內的非負有限 `ratio` **恆等**(`floor ratio` 是整數,`floor ratio >= maxSteps + 1` 等價於 `ratio >= maxSteps + 1`),而左式在 `ratio` 是 `Infinity` 或超出 `Int` 值域時仍然給出正確答案。兩條路徑的截斷分支輸出都是 `StepPlan maxSteps 0`,所以合法輸入的結果**逐位元不變**;`floor` 只會在 `ratio < maxSteps + 1` 時被呼叫,那時它必定安全。

**逐位元保證的邊界(本修復刻意不動的部分)**:

| 輸入類別 | 是否改變 | 理由 |
|---|---|---|
| `dt <= 0` | 不變 | 前置守衛未動 |
| 合法輸入且 `ratio` 落在 `Int` 值域 | **逐位元不變** | 新舊判斷式恆等,見上 |
| 合法輸入且 `ratio` 溢位/超出 `Int` 值域 | **改變**(本缺陷) | `0` 步或負步數 → `StepPlan maxSteps 0` |
| `elapsed = ±Inf`、`acc = ±Inf` | 不變 | 非有限輸入,C 面回 `PM_ERR_ARGS`,且 `test/FFIStepPlanSpec.hs` 把「規劃器單獨會毒化累加器」釘成回歸證據 |
| `dt = NaN` | 不變 | 同上;`NaN >= x` 為 `False`,自然走舊路徑 |
| `acc < 0`(負累加器) | 不變 | 非法輸入,C 面回 `PM_ERR_ARGS`,且 `FFIStepPlanSpec` 釘住「單獨呼叫會給負步數」 |
| `maxSteps < 0` | 不變 | 非法輸入,C 面回 `PM_ERR_ARGS`;新舊判斷式在此域仍恆等 |

為了讓「非有限輸入不變」這條成立,新判斷式要用 `finiteInputs` 把 `elapsed`/`acc` 為 `±Inf` 的情形排除在外——否則 `elapsed = +Inf` 會被新護欄一併「修好」,而那正是 host-runtime F005 用來證明 C 面參數檢查有必要的反例。

替代方案(未採用):在 `plan` 內對 `acc'` 先做飽和(`min someHuge acc'`)。這需要憑空選一個上限常數,而且改變的是資料而非判斷,合法輸入的逐位元保證更難論證。

## TodoList

- [x] T1: 在 `test/StepSpec.hs` 寫重現測試——比值溢位、比值有限但超出 `Int` 值域、累加器相加溢位三種形狀(修復前應失敗)  `dep: -`
- [x] T2: 補一條「合法輸入全域不變式」property:`0 <= stepsToRun <= maxSteps`、`accAfter` 有限且非負,涵蓋極端量級的 `dt`/`elapsed`/`acc`  `dep: T1`
- [x] T3: 補一條逐位元護欄,釘住不得改變的兩類輸入:典型 60Hz 案例的精確值,以及非有限/負累加器的歷史答案  `dep: T1`
- [x] T4: 修 `src/boundary/Magic/Step.hs` 的 `plan`——截斷判斷改在比值上進行,`finiteInputs` 守住非有限輸入的舊行為  `dep: T3`
- [x] T5: 完整 `cabal test`,特別確認 `test/FFIStepPlanSpec.hs` 的逐位元等價律仍綠  `dep: T4`
- [x] T6: 變異注入:把 `plan` 改回舊寫法,確認 T1–T3 的新測試全部變紅  `dep: T5`

## 驗證方式

```
cabal test --test-options='--match "Magic.Step.plan"'
cabal test --test-options='--match "fixed-timestep planner over the C ABI"'
cabal test
```

基線 1864 examples / 0 failures;修復後的例數為基線加上本文檔新增的條目。C 面不需要任何改動——`pm_plan_steps` 是轉呼 `Magic.Step.plan` 而非複製,修正會自動穿過去,而 `FFIStepPlanSpec` 的逐位元等價律正是這句話的證明。

## 待確認假設

- A1: 有限但**負的**累加器(`acc < 0`)在修復後仍會回負步數(`plan (1/60) 8 0.5 (-0.9)` = `StepPlan (-24) 0`)→ 採取:**不修**,維持原行為 → 影響:它是非法輸入(C 面回 `PM_ERR_ARGS`),而且 `test/FFIStepPlanSpec.hs` 正把這個值當作「C 面的參數檢查有存在必要」的證據;若判定它也該在 Haskell 面修,那條回歸斷言必須同時改寫,而那是 host-runtime 的檔案
- A2: `maxSteps` 大於 `2^53` 時 `fromIntegral maxSteps + 1` 不精確,新舊判斷式在該域不再嚴格恆等 → 採取:接受 → 影響:C 面的 `max_steps` 是 `int` (32 位元),Haskell 面唯一的大值呼叫是 `test/StepSpec.hs` 拿 `maxBound` 當「不截斷」用;而且在該域**舊式本來就壞**(`floor` 早已溢位),新式只是改成截斷,比原本更接近語意。無實際可達的行為退化
- A3: 本文檔放在 `boundary-host`(編排者指定),但被違反的契約條文 C5 寫在 [particle-simulation/design.md](../../particle-simulation/design.md),模組本體在 `src/boundary/` → 採取:照編排者指定的路徑建檔,不自行搬動 → 影響:若要讓「文檔所在子系統 = 契約擁有者」,需由編排者決定是搬文檔還是搬契約條文

## 修復紀錄

實際修法與「修復方向」一致,無偏差。`src/boundary/Magic/Step.hs` 的 `plan` 內層改成:

```haskell
ratio = acc' / dt + stepEpsilon
...
if finiteInputs && ratio >= fromIntegral maxSteps + 1
  then StepPlan maxSteps 0
  else let n = floor ratio
        in if n > maxSteps then StepPlan maxSteps 0
                           else StepPlan n (max 0 (acc' - fromIntegral n * dt))
where
  finiteInputs = not (isInfinite elapsed || isInfinite acc)
```

簽名、`StepPlan` 欄位、`dt <= 0` 前置守衛、epsilon 常數與其註解全部未動;`floor` 保留在原地,只是現在保證只會拿到落在 `Int` 值域內的引數。host-runtime 的任何檔案(`src/ffi/`、`cbits/`、`include/`)一行都沒改。

實測補充(比症狀表更廣):`floor` 交出的垃圾值**隨最佳化層級而變**——`ghc -e`(未最佳化)對 `plan 1e-300 8 1e300 0` 給 `stepsToRun = 0`,`-O2` 編出來的測試套件給 `minBound = -9223372036854775808`。也就是說同一份原始碼在 REPL 與出貨組建下壞法不同,這讓「零步」與「負步數」其實是同一個根因的兩張臉。

測試落點 `test/StepSpec.hs`(既有模組,`particle-magic.cabal` 未動),共 7 個新例:

- `B001: backlogs whose ratio to dt leaves Int's range` — 4 個具體案例加 1 條 property(`genLegalCall` 橫跨 `10^-320`…`10^307` 的指數域,20000 組通過)
- `B001: results the fix must leave bit for bit unchanged` — 16 列 `pinnedPlans` 逐位元對帳,加一條複製自 `FFIStepPlanSpec` 的「範圍外輸入答案不變」斷言

**變異注入(三輪,全部如預期)**:

| 變異 | 預期 | 實測 |
|---|---|---|
| 整條新護欄停用(`if False && ...`),等同舊寫法 | 5 個重現測試變紅、2 個保護測試維持綠 | 一致(`17 examples, 5 failures`) |
| 判斷式改成 `ratio > fromIntegral maxSteps`(差一) | 逐位元保護測試變紅 | **第一次跑時全綠——保護測試有洞**:`pinnedPlans` 缺「`n` 恰等於 `maxSteps` 且有餘額」的一列。補上該列與另外三列邊界後重跑,如預期變紅(`expected 4575957461383581968, but got 0`) |
| 拿掉 `finiteInputs` | 「範圍外輸入答案不變」變紅 | 一致(`elapsed = +Inf` 的 `accAfter` 從 `Infinity` 變成 `0.0`) |

第二輪那個洞值得記下來:逐位元保護測試如果只挑「典型」輸入,擋得住把功能拆掉的變異,卻擋不住把邊界挪半步的變異——而後者才是這次修改真正的風險面。

**驗證結果**:

- `cabal test --test-options='--match "Magic.Step.plan"'` → `17 examples, 0 failures`
- `cabal test --test-options='--match "fixed-timestep planner over the C ABI" --qc-max-success 3000'` → `9 examples, 0 failures`;**逐位元等價律 `is bit-identical to Magic.Step.plan over a frame sequence` 在 3000 組序列下仍綠**,`keeps its post-condition over the same sequences` 亦然。C 面確實是轉呼,修正自動穿了過去
- `cabal test` → `1879 examples, 0 failures`(基線 1864 + 本文檔 7 + 同時進行中的 host-runtime B001 新增 8)
- `cabal build all` → 全部目標編譯通過(含 `app/App/Loop.hs` 與 `particle-magic-ffi.dll`)

**順帶建議(不在本文檔範圍)**:`Magic.Step.plan` 沒有錯誤通道,對非法輸入只能回一個「看起來合法」的 `StepPlan`。C 面靠 `pm_plan_steps` 的參數檢查補上這一層,但 demo 外殼與未來的 Haskell 宿主沒有同等保護。若要根治 A1 那一類,應走 `/enhance-design` 討論是否讓邊界層提供一個帶驗證的入口,而不是在 `plan` 裡繼續堆特例。
