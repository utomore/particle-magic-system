---
id: F008
type: feature
title: host-doc-corrections
description: 修正粒子上限過期敘述並讓非 Haskell 範例改用時步規劃器
status: done
created: 2026-08-20
updated: 2026-08-21
depends-on: [F001, F005, F007]
related-adr: [ADR-022]
related-feature: []
---

# F008: 標頭與範例的過期敘述修正

## 功能概述

宿主讀的是標頭與範例，不是 `Magic.Compile`。今天這兩處對**粒子上限**與**固定時步**說的話，跟庫的實際行為對不上：

1. **粒子上限的敘述過期。** `include/particle_magic.h:172-176` 寫「`pm_max_particles()` … Today it answers `PM_MAX_PARTICLES`」，而 `PM_MAX_PARTICLES` 是凍結的 4096、查詢實際回 16384（`src/ffi/Magic/FFI.hs:203`、`src/core/Magic/Compile.hs:460`）。同一句過期敘述在 `FFI.hs:346` 又出現一次。標頭的 `PM_MAX_PARTICLES` define 註解（`:100-101`）更直接說它「Mirrors the core's budgetCap」——那條鏡射在 func-spec 0012 把核心上限提到 16384 時就斷了。
2. **範例照著過期敘述配容量。** `examples/c/main.c:72-77` 用 `PM_MAX_PARTICLES` 開六條靜態欄，`:118` 又把同一個常數當容量傳進 `pm_observe`。標頭檔頭的 usage sketch（`:21-24`）教的也是同一套。4097–16384 粒的法術會在 `pm_observe` 拿到 `PM_ERR_CAPACITY`，而 all-or-nothing 的錯誤路徑代表**整幀不畫**——看起來像閃爍，不像錯誤。（實測補充：16 份出貨範例陣最大的一張是 `grand-sigil.json` 的 1742 粒，全部遠低於 4096，所以這個缺陷今天是**潛伏**的，不是可見的失敗。見「相依性查證 §3」。）
3. **主迴圈沒有單幀最大步數。** `docs/integration.md:100-107` 的食譜、`examples/unity/SpellRenderer.cs:129-134` 的 `Update`、標頭檔頭的兩段 sketch，全部是裸的 `while (accumulator >= FIXED_DT)`。一次關卡載入的 hitch 會讓宿主對同一個法術連呼叫數百次推進（ADR-022 背景 4）。[F005](F005-step-planner-c-abi.md) 已把帶截斷的規劃器送上 C 面（`pm_plan_steps`）並提供帶錯誤碼的推進（`pm_advance_ex` / `pm_scene_advance_ex`），本功能是它的消費端。
4. **`docs/integration.md` 的兩處記帳過期。** §4.3 的錯誤表少了 `PM_ERR_INTERNAL`（−6）與 `PM_ERR_STATE`（−7）兩列（[F001](F001-exception-firewall.md) 把這項工作留給 F003 或 F008，編排者裁定歸本功能）；§8 誠實清單的「只有 win64 被完整實測」與 CI 實況不符——`.github/workflows/ci.yml:63` 的矩陣是 `[windows-latest, ubuntu-latest]`。

本功能**一個符號都不動**：改的是註解、文件與範例的主迴圈。

**驗收標準**（承 [design.md](../design.md) 的 host-doc-corrections 契約卡，逐條）：

1. 標頭與 Haskell 面關於「粒子上限查詢今日回傳凍結常數」的過期敘述改為實況。
2. C 最小宿主以**查詢值**配置容量，並能跑完所有出貨範例陣。
3. C、C#、Unity 範例的主迴圈全部改用時步規劃器且**帶單幀最大步數**。
4. 範例出貨清單測試照舊綠。

**明確不做**（契約卡原文）：不改變任何符號；不重寫範例的繪製部分；不動 Haskell 宿主範例（`examples/haskell/`、`docs/integration.md` §3）。

本文件另外裁定的不做（屬上一條的展開）：

- **不動 `PM_MAX_PARTICLES` 的值**，也不動 `bindings/csharp/ParticleMagic.cs:34` 的 `MaxParticles = 4096`——那是凍結常數的正確鏡射（`FFIContractSpec:129-131` 釘著），過期的是**敘述**而不是值。
- **不動 §4.4 與 §8 的控制代碼與 RTS 條目**：「重複 free、free 過再用是 UB」（`docs/integration.md:449`）、「單執行緒 handle」（`:712`）、「RTS 不可重啟」（`:713`）分別是 F002、F004、F003 的驗收要改寫的敘述，本功能改了會和它們對撞。
- **不新增出貨範例陣**，因此「4097 粒以上的法術」在本輪沒有可執行的反例，只有文字守門（見「待確認假設 A3」）。

## 相依性

最終 `depends-on: [F001, F005, F007]`，全部是**同階段（W1）的排程先後**，沒有一項會讓本功能停擺：

| 相依 | 性質 | 為什麼 |
|---|---|---|
| **F005** step-planner-c-abi | **真正的介面相依** | 本功能的範例與文件呼叫 `pm_plan_steps`、`pm_advance_ex`、`pm_scene_advance_ex`——三個符號今天不存在（`grep pm_plan_steps include/particle_magic.h` 為空），由 F005 新增；C# 那三個 `DllImport` 也由 F005 T7 新增。F005 的相依性段已明寫「本功能不動 `examples/`、`docs/integration.md`」，方向是單向的 |
| **F001** exception-firewall | 常數來源 ＋ 執行順序 | §4.3 新增的兩列描述 `PM_ERR_INTERNAL`（−6）與 `PM_ERR_STATE`（−7）；這兩個 `#define` 由 F001 加進標頭（F001 §「新增的介面」）。T9 的守門測試方向是「標頭的每個 `PM_ERR_*` 都要出現在 §4.3 表格」，所以 F001 先落地時本功能自動被涵蓋，F001 後落地時也不會讓測試紅——但**文件描述的常數要真的存在才誠實**，故排在 F001 之後 |
| **F007** packaging-content | 執行順序（同檔不同章節） | 兩者都改 `docs/integration.md`：F007 在 **§4 新增** MSVC 連結與 macOS `@rpath` 兩節；本功能改 **§2.4 / §4.2 / §4.3 / §5.4 / §6 / §8**。沒有任何一行重疊，但同一個檔案的連續編輯需要順序。避免衝突的作法見下 |

**與 F007 的同檔衝突怎麼避免**（編排者需要的具體做法）：

1. **先 F007、後 F008**。F007 是**純新增章節**（在 §4 尾端插入兩個 `###`），F008 是**就地改寫既有段落**；先插入再改寫，改寫的錨點（`### 2.4`、`### 4.2`、`### 4.3`、`### 5.4`、`## 8`）不會被移動。反過來則 F008 的行號在 F007 插入後全部失效。
2. **兩者都不碰 §1 的路線表與檔頭的版本沿革 block**（`:15-18`）以外的共用區塊；版本沿革由**後落地的那一個**加一行，先落地者不寫（避免兩行互蓋）。本功能落地時若 F007 已合併，就在 `:15` 之上補一行 1.4；若順序被調換，改補 1.5，內容不變。
3. 兩者的守門測試落在**不同檔案**（F007 是 `test/PackagingSpec.hs`，本功能是 `test/ExampleLoopSpec.hs`），只在 `particle-magic.cabal` 的 test-suite `other-modules` 清單相鄰——那是逐行 append，git 可自動合併。

`depends-on` 的三項都不是「等它做完才能開始設計」，只是「合併順序」。本功能與 **F002 handle-generation**、**F003 rts-config-init**、**F004 thread-model**、**F006 oop-load-smoke** 完全無關，可平行。

**與編派輸入的差異（需編排者裁決）**：委派 prompt 指定 `depends-on: [F005, F007]`。介面表反推出的候選集合是 `{F001, F005, F007}`——§4.3 那兩列消費的是 F001 新增的常數，這是「一致性檢查」第 2 條要求補進去的漏填項，故本文件填了三項。若編排者堅持原值，刪掉 `F001` 一個 token 即可，內文與 TodoList 不受影響。

## 對應的 Level 2 契約

契約卡寫的是「**無新增**；修正 C1.1 相關的標頭註解；範例改用 C1.7」。逐條確認未超出：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **C1.1 生命週期**（既有） | 只改註解：`pm_max_particles()`、`PM_MAX_PARTICLES` define、`pm_cast_ex` 的預算說明、檔頭兩段 usage sketch。**簽名、常數值、結構版面零變更** | 否 |
| **C1.7 時步規劃** | 純消費：範例與文件的主迴圈改用 F005 提供的 `pm_plan_steps` | 否（消費端） |
| **C1.12 推進的錯誤碼變體** | 純消費：範例改用 `pm_advance_ex` / `pm_scene_advance_ex` 並檢查回傳碼 | 否（消費端） |
| **C1.9 錯誤碼** | 只把 `PM_ERR_INTERNAL` / `PM_ERR_STATE` 寫進 `docs/integration.md` §4.3 的錯誤表；**常數本身由 F001 加** | 否 |
| **C1「只加不改」** | 不新增也不移除任何符號、`#define` 或結構欄位；`PM_ABI_VERSION` 維持 1 | 否 |
| **I5（M5／M6／M7 → 標頭）** | 範例與文件只認標頭；本功能把「範例照著標頭的過期註解寫」這條錯誤的資訊流修好，並補上守門 | 否——正是 I5 的兌現 |
| **M7 封裝與整合文件** | `docs/integration.md` §2.4 / §4.2 / §4.3 / §5.4 / §6 / §8、`include/particle_magic.h` 的註解 | 否 |
| **M6 非 Haskell 宿主範例** | `examples/c/main.c`、`examples/c/scene.c`、`examples/unity/SpellRenderer.cs`、`examples/unity/PmSmoke.cs`、`examples/unity/README.md` | 否 |
| **資料流管線** | 不在管線上——契約卡原文 | 否 |

**未超出的證明**：`include/particle_magic.h` 的 diff 全部落在 `/* */` 內；`FFI.hs` 的 diff 全部落在 `-- |` haddock 內；其餘變更全在 `examples/`、`docs/`、`test/` 三個資料夾。`FFIContractSpec` 的三方對帳（header ≡ foreign exports ≡ `.def`）與 `BindingContractSpec` 的雙向對帳因此逐字不受影響。

## 實作方式

### 一、粒子上限：把「今日等於凍結常數」換成「今日已經大於它」

四處敘述要改（行號為本輪查證值，實作時以錨定字串為準）：

| 位置 | 今天寫什麼 | 為什麼錯 |
|---|---|---|
| `include/particle_magic.h:100-101` | 「Upper bound on the particles a single spell can produce … Mirrors the core's budgetCap」 | 兩句都錯：4096 既不是單一法術的上限（16384 才是），也不再鏡射 `budgetCap` |
| `include/particle_magic.h:104-109` | 「A later core **may** raise the real cap」 | 已經 raise 過了（func-spec 0012），`may` 讀起來像還沒發生 |
| `include/particle_magic.h:172-176` | 「Today it answers `PM_MAX_PARTICLES`」 | 實際回 16384 |
| `include/particle_magic.h:187-190`（`pm_cast_ex`） | 「asks for more particles than `PM_MAX_PARTICLES`」（`:188-189`） | 預算閘門比的是 `budgetCap`（16384），不是 4096；照這句寫的宿主會以為 5000 粒的陣會被拒 |
| `src/ffi/Magic/FFI.hs:343-349` | 「Today it answers `@PM_MAX_PARTICLES@` (4096)」 | 同上；同一檔 `:187-201` 的 `pmMaxParticles` haddock **是對的**（它已記載 4096 → 16384 那次），只有這段沒跟上 |

改寫的原則是**讓新敘述不再依賴當下的數值**，否則下次核心上限再變又會過期：

- `PM_MAX_PARTICLES` 的定位改寫成「**ABI 第一代的容量下限**，凍結在 4096，只為讓舊標頭編出來的宿主永遠配得夠大」——不再宣稱它是上限、也不再宣稱它鏡射核心。
- `pm_max_particles()` 的定位改寫成「**跟著核心走的真值；它今天已經大於 `PM_MAX_PARTICLES`**，所以任何想吃到完整上限的宿主都必須從查詢配置」。
- `pm_cast_ex` 的 `PM_ERR_BUDGET` 說明改寫成「超過 `pm_max_particles()` 回報的上限」。
- `FFI.hs` 的 haddock 指回同檔 `pmMaxParticles` 的說明（那段已經正確且完整），避免第三份會過期的敘述。

**哨兵**：新敘述裡放一個測試釘得住的詞（沿用標頭既有的 `right-handed` / `0xRRGGBBAA` 手法），讓它不會被人「順手精簡」掉。用哪個詞屬實作自主權，但**測試與散文必須用同一個**；本文件以 `more than PM_MAX_PARTICLES` 作為預設。

### 二、標頭檔頭的兩段 usage sketch

`:14-28` 的單張陣 sketch 與 `:36-46` 的場景 sketch 是宿主看到的第一段程式碼，兩處都要示範正確作法：

```c
 *   pm_init();
 *   int cap = pm_max_particles();     /* NOT PM_MAX_PARTICLES -- see below */
 *   /* ... allocate six columns of `cap` elements each ... */
 *
 *   double acc = 0;
 *   while (!pm_is_finished(s)) {
 *       int steps;
 *       pm_plan_steps(FIXED_DT, 8, seconds_since_last_frame, acc, &steps, &acc);
 *       while (steps-- > 0) pm_advance_ex(s, FIXED_DT_F);
 *       int n = pm_observe(s, px, py, pz, size, life, color, cap, info, 8);
 *       ...  feed your vertex buffer from the six arrays ...
 *   }
```

場景 sketch（`:40-41`）同構，但容量仍取自 `pm_scene_new` 的 `global_cap`——`:48` 起的「Two things to get right」第一點（`:50-54`）已經把這條講對了，**不要動它**。

`8` 這個單幀最大步數不是憑空選的：`app/Main.hs:47` 的 `lcMaxStepsPerFrame = 8` 是 demo 外殼跑了整個 POC 的值，範例沿用同一個數字，宿主才有一個有來歷的起點。

### 三、`FIXED_DT` 的雙精度／單精度紀律（逐位元不變的關鍵）

`pm_plan_steps` 的參數是 `double`，`pm_advance` / `pm_advance_ex` 的 `dt` 是 `float`。這兩個值**必須是同一個數**，否則累加器與實際推進量會慢慢分家。作法是先定 `float`，再加寬：

```c
#define FIXED_DT_F (1.0f / 60.0f)          /* what pm_advance_ex receives */
#define FIXED_DT   ((double)FIXED_DT_F)    /* what pm_plan_steps plans in */
```

這條紀律同時是 `examples/c/main.c` 輸出**逐位元不變**的證明：範例是固定幀數的 headless smoke，每幀餵給規劃器的 `elapsed` 就是一個 `FIXED_DT`，於是
`acc' = 0 + FIXED_DT`、`n = floor(acc'/FIXED_DT + 1e-9) = 1`、`acc = max 0 (acc' - 1*FIXED_DT) = 0`
（`plan` 的三行本體，`src/boundary/Magic/Step.hs:31-41`）。每一幀恰好一次 `pm_advance_ex(s, FIXED_DT_F)`，與今天 `main.c:116` 的 `pm_advance(spell, DT)` **完全相同的呼叫**，所以 `ExampleHostSpec` S4 的逐幀 golden 一個字都不會變。

### 四、`examples/c/main.c`

兩件事，繪製部分（`printf` 的欄位與格式）一個字都不動：

1. **容量改成查詢值**。六條靜態陣列（`:72-77`）改為 `pm_init()` 之後以 `pm_max_particles()` 的回傳值 `malloc`；`batch_info`（`:78`）與 `MAX_BATCHES` 不變（它與粒子上限無關）。`:118` 傳進 `pm_observe` 的容量改成同一個 `cap` 變數。配置失敗要走既有的錯誤路徑（`return 1` 前先 `pm_shutdown()`）。**範本是 `examples/c/scene.c:81-97` 的 `alloc_columns` / `free_columns`**——那一份已經做對了（從 `pm_scene_new` 的 cap 配置），照抄它的形狀，兩份 C 範例的記憶體處理因此長得一樣。
2. **主迴圈改用規劃器**。`:110-137` 的 `for (frame …)` 保持 120 幀不變（那是 golden 的來源），迴圈體內 `pm_advance(spell, DT)`（`:116`）換成「規劃 → 依步數推進」，並檢查 `pm_plan_steps` 與 `pm_advance_ex` 的回傳碼（非 `PM_OK` 就照既有 `pm_observe` 失敗的樣子印錯誤並收尾）。註解要說明「這裡的 `elapsed` 是合成的固定值，真實宿主餵的是牆鐘差」。

### 五、`examples/c/scene.c`

容量已經對了（`:101-116` 的 `probe_budget` ＋ `:222` 的 `cap = 2 * one`），**不動**。只改 `run_until`（`:175-188`）的 `pm_scene_advance(scene, DT)`：同樣改成規劃 → 依步數 `pm_scene_advance_ex`。這支範例每 60 幀才 `report` 一次，且沒有 golden 比對，但「一幀一步」的節奏必須維持，否則 `pm_scene_count` 的收斂時機會變、印出來的 trace 會漂。

### 六、`examples/unity/SpellRenderer.cs`

容量已經對了（`:72-75` 已經是 `Pm.pm_max_particles()`），**不動**。要改的是 `Update`（`:122-134`）與它的兩個欄位：

- `accumulator`（`:56`）**型別由 `float` 改為 `double`**——規劃器是雙精度，單精度累加器會漂（F005 在標頭註解裡明寫了這個理由）。**欄位名稱必須維持 `accumulator`**：`PmSmoke.cs:318` 是用 `type.GetField("accumulator", Private)` 反射拿它的。
- 新增一個 `const int MaxStepsPerFrame = 8;`（與 C 範例、demo 外殼同值）。
- 迴圈改為：把 `Time.deltaTime` 與現在的 `accumulator` 餵給 `Pm.pm_plan_steps`，回 `PM_OK` 才寫回累加器並跑 `steps` 次 `Pm.pm_advance_ex(spell, FixedDt)`；非 `PM_OK` 記一次 `Debug.LogWarning` 並且**不推進、不寫回累加器**（規劃器對非法輸入一個位元組都不寫，見 F005 T2）。
- `FixedDt`（`:40`）維持 `float`（`pm_advance_ex` 吃它），另取一個 `double` 常數給規劃器用（由 `FixedDt` 隱式加寬，同§三的紀律）。
- 檔頭註解第 2 條（`:9-10`）「A fixed-timestep accumulator」要補上「帶單幀上限，交給庫的規劃器算」。

### 七、`examples/unity/PmSmoke.cs`

`Pump`（`:314-325`）用反射把 `accumulator` 設成 `0.1f`。欄位一旦變成 `double`，`SetValue(renderer, 0.1f)` 會在執行期丟 `ArgumentException`——**這是本功能唯一一處會真的壞掉的地方**，不改的話 Unity smoke 從 G/H 兩節開始全紅。改成 `0.1`（`double`），並把註解裡的「the accumulator is primed」補一句「型別跟著 `SpellRenderer` 走」。

`:176` 的 `Check(true, "SpellRenderer.Awake allocated its columns from pm_max_particles()")` 維持不變（它敘述的事實沒變）。

### 八、`docs/integration.md`

| 位置 | 改什麼 |
|---|---|
| **§2.4 固定時步**（`:94-107`） | 食譜換成 `pm_plan_steps` 版本，並補一段說明「單幀最大步數是死亡螺旋防護：截斷時丟棄積壓，模擬變慢而不是凍結」（語意出處 `Magic.Step.plan` 的註解，`src/boundary/Magic/Step.hs:24-26`）。同時說明規劃器是**雙精度**、與 Haskell 面同一份實作 |
| **§2.5 六條陣列要開多大**（`:111-124`） | **內容已經正確**（它就是那條被範例違反的規則）。只補一句指回 §4.2 的可執行版本，讓「文件說對、範例做錯」不再發生 |
| **§4.2 最小完整迴圈**（`:380-428`） | 六條靜態陣列改成從 `pm_max_particles()` 配置；主迴圈改用規劃器與 `pm_advance_ex`；`:430` 的「`examples/c/main.c` 是這段的完整可執行版」保持成立（兩邊必須同步改） |
| **§4.3 錯誤處理**（`:434-440`） | 表格新增兩列：`PM_ERR_INTERNAL`（−6，防火牆攔到的庫內部失敗，宿主不必重試，進程不受影響）與 `PM_ERR_STATE`（−7，宿主呼叫順序錯：未初始化就呼叫、關閉後再初始化、重複帶設定初始化、設定在當前平台無法生效）。語意逐字取自 [design.md](../design.md) C1.9 與 F001 §「新增的介面」，不自創第二套說法 |
| **§5.4 每幀**（`:625-646`） | 骨架第 1 步換成規劃器版本，與改寫後的 `SpellRenderer.cs` 同形 |
| **§6 路線 D 第 5 條**（`:678`） | 「固定 `dt`；一幀多步 `advance`、只 `observe` 一次」補上「用 `pm_plan_steps` 規劃，別自己寫 `while`」 |
| **§8 誠實清單**（`:706-721`） | 見下 |

**§8 的三列**：

- `:715` **「只有 win64 被完整實測」→ 改為實況**：`.github/workflows/ci.yml:63` 的矩陣是 `[windows-latest, ubuntu-latest]`，兩個平台每次都跑完整 hspec 套件；macOS 只有建置設定、沒有機器驗過（措辭與 F007 的 `verified: false` 對齊）。
- `:714` **「DLL 約 46 MB」→ 不改**：本輪實測 `particle-magic-ffi.dll` 為 47,896,064 bytes ＝ **45.7 MiB**，敘述正確。只補一句量測基準（GHC 9.14.1、`standalone`），讓下一個人不必再量一次。委派清單把它列為過期敘述，本文件以量測結果推翻（見「待確認假設 A4」）。
- `:708` **粒子上限那一列**已經是對的（明寫 16384、明寫「請用執行期查詢」）——**不動**，只確認它與改寫後的標頭用同一套說法。

### 九、`examples/unity/README.md`

`:60` 的「固定時步｜accumulator，一幀可能 `pm_advance` 好幾次」與 `:116` 的場景片段是同一件事的文字版，跟著 `SpellRenderer.cs` 一起改成規劃器版本。§5 的表格結構、§7 的 smoke 說明不動。

### 十、守門測試 `test/ExampleLoopSpec.hs`（新檔）

本功能改的全是散文與範例，`cabal build` 不會替它們把關，所以照本 repo「把文件當被測物」的既有紀律補一支 spec。它只做文字與值的比對，不連結任何範例：

- 沿用 `readUtf8`（各 spec 自帶一份小工具是本 repo 的既有紀律，`ReleaseDocSpec` 與 `ExampleHostSpec` 都各有一份）。
- 平台清單那一條沿用 `CIWorkflowSpec:87` 的 `matrixOses` 模式（同樣自帶一份，不 import）。
- 新檔要進 `particle-magic.cabal` 的 `test-suite spec` 的 `other-modules`（`test/Spec.hs:1` 是 `hspec-discover`，但 cabal 仍要列）。

## 使用到的既有串接介面

**本功能無新增介面**——消費 C1.1（標頭註解）、C1.7 與 C1.12（F005 的三個新符號）、C1.9（F001 的兩個新常數）。

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `int pm_max_particles(void);` | `include/particle_magic.h`:176 | - | 範例改用它配置容量；它的註解就是要改的過期敘述之一 |
| `#define PM_MAX_PARTICLES 4096` | `include/particle_magic.h`:102 | - | 凍結常數；值不動，改的是它上下兩段註解（`:100-101`、`:104-108`） |
| `pm_max_particles :: IO CInt`（`pure pmMaxParticles`） | `src/ffi/Magic/FFI.hs`:350-351 | - | Haskell 面的同一個查詢；`:343-349` 的 haddock 是要改的第二處過期敘述 |
| `pmMaxParticles :: CInt`（`= 16384`） | `src/ffi/Magic/FFI.hs`:202-203 | - | 查詢的實際回傳值——「今日回傳 4096」為假的機械證據 |
| `budgetCap :: Int`（`= 16384`） | `src/core/Magic/Compile.hs`:459-460 | - | 核心真正的上限；`PM_MAX_PARTICLES` 的「Mirrors the core's budgetCap」為假的機械證據 |
| `maxSpellParticles = budgetCap` | `src/boundary/Magic/Interface.hs`:487 | - | Haskell 宿主查上限的入口；§8 已正確指向它，確認不必改 |
| `int pm_observe(PmSpell* spell, float* pos_x, float* pos_y, float* pos_z, float* size, float* life, uint32_t* color, int capacity, int* batch_info, int max_batches);` | `include/particle_magic.h`:228-231 | - | 範例把 `capacity` 從常數換成查詢值的那一個參數 |
| `PmScene* pm_scene_new(int global_cap);` | `include/particle_magic.h`:309 | - | 場景範例的容量來源（`scene.c` 已正確，用來確認不必改） |
| `void pm_advance(PmSpell* spell, float dt);` | `include/particle_magic.h`:199 | - | 今天範例呼叫的推進；改用 `_ex` 變體後保留（合法 `dt` 行為相同） |
| `void pm_scene_advance(PmScene* scene, float dt);` | `include/particle_magic.h`:337 | - | 同上，場景版 |
| `int pm_plan_steps(double dt, int max_steps, double elapsed, double acc_in, int* out_steps, double* out_acc);` | `include/particle_magic.h`（F005 新增，尚不存在） | **F005** | 範例與文件主迴圈的規劃器；相依於 F005 的介面約定而非既有程式碼 |
| `int pm_advance_ex(PmSpell* spell, float dt);` | `include/particle_magic.h`（F005 新增，尚不存在） | **F005** | 範例主迴圈帶錯誤碼的推進 |
| `int pm_scene_advance_ex(PmScene* scene, float dt);` | `include/particle_magic.h`（F005 新增，尚不存在） | **F005** | `scene.c` 的推進 |
| `#define PM_ERR_INTERNAL (-6)` / `#define PM_ERR_STATE (-7)` | `include/particle_magic.h`（F001 新增，尚不存在） | **F001** | §4.3 錯誤表新增的兩列所描述的常數 |
| `plan :: Double -> Int -> Double -> Double -> StepPlan` | `src/boundary/Magic/Step.hs`:27 | - | 規劃器的語意來源（截斷丟積壓、epsilon、`dt<=0` 回 0 步）；文件敘述照它寫，不自創 |
| `lcMaxStepsPerFrame = 8` | `app/Main.hs`:47 | - | 單幀最大步數 `8` 的來歷——demo 外殼跑完整個 POC 的值 |
| `public static extern int pm_max_particles();` | `bindings/csharp/ParticleMagic.cs`:81-82 | - | Unity 範例已在用；確認容量那半邊不必改 |
| `public const int MaxParticles = 4096;   // PM_MAX_PARTICLES (see pm_max_particles)` | `bindings/csharp/ParticleMagic.cs`:34 | - | 凍結常數的正確鏡射；確認**不動**（`BindingContractSpec` 釘著行尾註解格式） |
| `public const int Ok = 0;` | `bindings/csharp/ParticleMagic.cs`:37 | - | Unity 迴圈檢查 `pm_plan_steps` 回傳碼用 |
| `float accumulator;`（`SpellRenderer` 的私有欄位宣告） | `examples/unity/SpellRenderer.cs`:56 | - | 要改型別為 `double` 的欄位；名稱不可改（被反射用） |
| `type.GetField("accumulator", Private)` ＋ `accumulator.SetValue(renderer, 0.1f)` | `examples/unity/PmSmoke.cs`:318,322 | - | 會被欄位型別變更打壞的唯一一行；必須同批改成 `0.1` |
| `it "reproduces every frame line through the C ABI, as examples/c/main.c drives it"` | `test/ExampleHostSpec.hs`:158-163 | - | `main.c` 輸出逐位元不變的既有回歸守門（120 幀逐行比對 golden） |
| `extraSourceFiles :: IO [FilePath]`（讀 `particle-magic.cabal` 的 `extra-source-files:`） | `test/ExampleHostSpec.hs`:364-365 | - | 「範例出貨清單測試照舊綠」的那一條；本功能不新增範例檔，故自動維持 |
| `exampleFiles :: IO [FilePath]`（只掃 `examples/haskell`） | `test/ExampleHostSpec.hs`:395-398 | - | 查證：出貨清單守門**只涵蓋 Haskell 範例**，`examples/c` 與 `examples/unity` 沒有內容守門——這正是本功能要補 `ExampleLoopSpec` 的理由 |
| `headerDefines :: IO [(String, Int)]` | `test/FFIContractSpec.hs`:314-315 | - | T9 的錯誤碼雙向對帳直接消費它列出的每個 `PM_ERR_*` |
| `readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs`:351-352 | - | 標頭／文件的文字斷言讀檔；新 spec 自帶一份同形的 |
| `isInfixOf' :: String -> String -> Bool` | `test/FFIContractSpec.hs`:413-414 | - | 哨兵詞斷言的既有寫法（`right-handed` / `0xRRGGBBAA` 用的就是它） |
| `it "pins PM_MAX_PARTICLES at the first generation's value (frozen header)"` ／ `it "mirrors the core's cap through the pm_max_particles query"` | `test/FFIContractSpec.hs`:129-136 | - | 既有的兩條鏡射律；本功能的散文必須與它們說同一件事，且不得讓它們變紅 |
| `matrixOses :: String -> [String]`（讀 `os:` 那一行） | `test/CIWorkflowSpec.hs`:87-89 | - | §8 平台敘述對帳的既有模式；新 spec 自帶一份，不 import |
| `os: [windows-latest, ubuntu-latest]` | `.github/workflows/ci.yml`:63 | - | 「只有 win64 被完整實測」為假的機械證據 |
| `extra-source-files: include/particle_magic.h / examples/c/main.c / examples/c/scene.c / bindings/csharp/ParticleMagic.cs / examples/haskell/*` | `particle-magic.cabal`:40-48 | - | 查證：兩支 C 範例已在出貨清單內、`examples/unity/` 不在（見 A5） |
| `{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` | `test/Spec.hs`:1 | - | 新 spec 會被自動發現，但仍要進 cabal `other-modules` |

三列來源文檔非 `-`：`pm_plan_steps` / `pm_advance_ex` / `pm_scene_advance_ex` 指向 **F005**，兩個錯誤碼常數指向 **F001**。這兩份文檔的介面都尚未落地，因此本功能對它們的相依是**依文檔的介面約定**，不是既有程式碼——F005 §「新增的介面」與 F001 §「新增的介面」是唯一依據。其餘每一列都已打開原始檔讀到實際內容。

## 新增的介面

**無新增。** 本功能不新增任何 C 符號、`#define`、Haskell 匯出、C# extern 或 JSON 鍵；`PM_ABI_VERSION` 維持 1，`.def` 的 `EXPORTS` 一個字不動。

唯一新增的檔案是測試：`test/ExampleLoopSpec.hs`（hspec spec，不對外提供任何介面），以及它在 `particle-magic.cabal` 的 `other-modules` 一列。

## TodoList

- [x] T1: 標頭的粒子上限敘述改為實況——`PM_MAX_PARTICLES` define 的上下兩段註解、`pm_max_particles()` 的註解、`pm_cast_ex` 的預算說明，並植入哨兵詞　`dep: -`
- [x] T2: `src/ffi/Magic/FFI.hs` 的 `pm_max_particles` haddock 改為實況，指回同檔 `pmMaxParticles` 的既有說明，不製造第三份敘述　`dep: T1`
- [x] T3: 標頭檔頭兩段 usage sketch（單張陣、場景）改用 `pm_max_particles()` 配容量 ＋ `pm_plan_steps` ＋ `pm_advance_ex`／`pm_scene_advance_ex`，單幀最大步數 8　`dep: F005, T1`
- [x] T4: `examples/c/main.c` 以 `pm_max_particles()` 動態配置六條欄（形狀照 `scene.c` 的 `alloc_columns`／`free_columns`），`pm_observe` 的容量改用同一個值，繪製與輸出格式不動　`dep: T3`
- [x] T5: `examples/c/main.c` 主迴圈改用 `pm_plan_steps` ＋ `pm_advance_ex`（`FIXED_DT_F` / `FIXED_DT` 雙常數紀律），120 幀輸出逐位元不變　`dep: F005, T4`
- [x] T6: `examples/c/scene.c` 的 `run_until` 改用 `pm_plan_steps` ＋ `pm_scene_advance_ex`；容量路徑（`probe_budget`）不動　`dep: F005, T5`
- [x] T7: `examples/unity/SpellRenderer.cs`：`accumulator` 改 `double`（名稱不變）、新增 `MaxStepsPerFrame = 8`、`Update` 改用 `pm_plan_steps` ＋ `pm_advance_ex` 並檢查回傳碼；容量路徑與繪製不動　`dep: F005`
- [x] T8: `examples/unity/PmSmoke.cs` 的 `Pump` 反射賦值改為 `double`，註解同步；`examples/unity/README.md` 的兩處時步敘述跟著改　`dep: T7`
- [x] T9: `docs/integration.md` 三段迴圈食譜改用規劃器——§2.4、§4.2（容量同時改用查詢值）、§5.4、§6 第 5 條；§2.5 補一句指回 §4.2　`dep: T5, T7`
- [x] T10: `docs/integration.md` §4.3 錯誤表新增 `PM_ERR_INTERNAL`（−6）與 `PM_ERR_STATE`（−7）兩列，語意逐字取自 C1.9　`dep: F001`
- [x] T11: `docs/integration.md` §8 誠實清單更新：平台實測改為 CI 矩陣的實況（Windows ＋ Linux，macOS 未驗）、DLL 大小補量測基準（值不變）　`dep: -`
- [x] T12: 新增 `test/ExampleLoopSpec.hs` 並登記進 `particle-magic.cabal` 的 `test-suite spec` `other-modules`，`cabal test` 全綠（含既有 `ExampleHostSpec`、`FFIContractSpec`、`BindingContractSpec` 無回歸）　`dep: T1..T11`
- [x] T13（編排者加派，F002 的 A8）: 標頭 `pm_scene_new` 的「Never returns NULL in this generation」改寫為準確敘述；`FFI.hs` 同一句一併改　`dep: -`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIContractSpec`（既有，擴充）— `it "says what pm_max_particles actually answers"` | 標頭**不含** `"Today it answers"`；**含**哨兵 `"more than PM_MAX_PARTICLES"`；並把散文釘在事實上：`pm_max_particles` 的回傳值 > `lookup "PM_MAX_PARTICLES" headerDefines`。三條一起紅才代表敘述與實況又分家（既有的 `:129-136` 兩條鏡射律不動、仍須綠） |
| T2 | `FFIContractSpec`（既有，擴充）— `it "keeps the Haskell-side haddock in step with the query"` | `readUtf8 "src/ffi/Magic/FFI.hs"` 不含 `"Today it answers"`，且 `pm_max_particles` 的 haddock 含同一個哨兵詞——同一個缺陷在兩個檔案各釘一次 |
| T3 | `ExampleLoopSpec` — `it "teaches the query and the planner in the header's usage sketches"` | 標頭前 60 行（檔頭註解）含 `pm_max_particles()`、`pm_plan_steps`、`pm_advance_ex`、`pm_scene_advance_ex`，且**不含** `"PM_MAX_PARTICLES, info"`（今天 `:24` 那一行的字面）；場景 sketch 仍保留 `global_cap` 那句 |
| T4 | `ExampleLoopSpec` — `it "sizes examples/c/main.c from the query, never from the frozen macro"` | `main.c` 含 `pm_max_particles(`，且**整份不含** `PM_MAX_PARTICLES`（改完之後它一次都不需要）；含 `free(` 對應每一條 `malloc` 的欄（以出現次數比對，防止漏 free 一條） |
| T5 | `ExampleHostSpec`（既有）S4 — `it "reproduces every frame line through the C ABI, as examples/c/main.c drives it"` | 逐位元不變的總驗收：120 幀的每一行 `frame … age … batches … particles … checksum` 與 golden 相同。改成規劃器後每幀仍恰一步，這條不許變紅——它是「不要動 golden」的機械保證 |
| T6 | `ExampleLoopSpec` — `it "plans the scene example's steps too"` | `scene.c` 含 `pm_plan_steps` 與 `pm_scene_advance_ex`、不含裸的 `pm_scene_advance(scene, DT)`；且仍含 `probe_budget` 與 `alloc_columns(&cols, cap)`（容量路徑沒被順手改壞） |
| T7 | `ExampleLoopSpec` — `it "plans SpellRenderer's steps with a per-frame ceiling"` | `SpellRenderer.cs` 含 `pm_plan_steps`、`pm_advance_ex`、一個名稱含 `MaxSteps` 的常數且其值為 `8`；**不含** `while (accumulator >=`；欄位宣告行含 `double accumulator` |
| T8 | `ExampleLoopSpec` — `it "primes the accumulator with the type SpellRenderer declares"` | `PmSmoke.cs` 仍以 `GetField("accumulator"` 取欄位，且它的 `SetValue` 引數**不帶 `f` 後綴**（`0.1` 而非 `0.1f`）——這正是欄位改型別後會在 Unity 執行期丟 `ArgumentException` 的那一行；README 含 `pm_plan_steps` |
| T9 | `ExampleLoopSpec` — `it "shows the planner in every loop recipe the guide prints"` | `docs/integration.md` 的 §2.4、§4.2、§5.4 三段各自含 `pm_plan_steps`；全檔**不含** `while (accumulator >= FIXED_DT)` 與 `while (accumulator >= FixedDt)`；§4.2 那段不含 `PM_MAX_PARTICLES`；§4.2 仍含指向 `examples/c/main.c` 的那一句（兩邊同步的錨） |
| T10 | `ExampleLoopSpec` — `it "documents every error code the header defines"` | 單向對帳：`headerDefines` 裡每個 `PM_ERR_*` 名稱都出現在 §4.3 的表格區塊內。方向選單向是刻意的——F001 未落地時不會誤紅，落地後漏補就紅；`shouldSatisfy not . null` 擋掉 vacuity |
| T11 | `ExampleLoopSpec` — `it "names the platforms the CI matrix actually runs"` | 自帶的 `matrixOses` 解出 `.github/workflows/ci.yml` 的 `os:` 清單（今天 `["ubuntu-latest","windows-latest"]`），斷言 §8 的平台那一列同時提到 Windows 與 Linux，且**不含** `"只有 win64"`；DLL 大小那一列仍含 `MB`（值不驗，只驗這句沒被刪） |
| T12 | `cabal test` 全綠 | 總驗收：`ExampleLoopSpec` 已在 `particle-magic.cabal` 的 `other-modules`（以掃 cabal 檔斷言，沿用 `ExampleHostSpec` 的作法），且 `ExampleHostSpec`（含 S5 出貨清單）、`FFIContractSpec` 三方對帳、`BindingContractSpec` 雙向對帳、`CIWorkflowSpec` 全部無回歸 |

## 待確認假設

- **A1: 兩支 C 範例沒有真實時鐘，餵給規劃器的 `elapsed` 只能是合成值。** `main.c` 是固定 120 幀的 headless smoke，輸出被 `ExampleHostSpec` S4 逐行釘死。→ **採取**：每幀餵 `FIXED_DT`（恰一個固定步），規劃器每幀回 1 步、累加器恆為 0，呼叫序列與今天完全相同，golden 因此逐位元不變；註解說明「真實宿主餵的是牆鐘差」。→ **影響**：範例因此**不會實際示範截斷**（單幀最大步數只被傳進去、不被觸發）。若編排者要求範例真的跑一次 hitch，S4 的 golden 會全紅，出路是另開一支示範程式或重錄 golden——兩者都超出「不重寫範例」的界線，應另立 feature。
- **A2: 單幀最大步數取 `8`。** 契約卡只說「帶單幀最大步數」，沒說幾。→ **採取**：`8`，依據是 `app/Main.hs:47` 的 `lcMaxStepsPerFrame = 8`（demo 外殼跑完整個 POC 的值），三份範例與文件用同一個數字。→ **影響**：若日後認定應隨 `FIXED_DT` 導出（例如「最多落後 0.13 秒」），改的是三個常數與 T7 的值斷言，設計不動。
- **A3: 「C 最小宿主能跑完所有出貨範例陣」在本輪無法用一張超過 4096 粒的陣來證明。** 實測 16 份 `assets/spells/*.json` 最大為 `grand-sigil.json` 的 1742 粒，全部低於 4096——今天用凍結常數也跑得完，缺陷是潛伏的。→ **採取**：驗收改以**文字守門**兌現（T4：`main.c` 不得再出現 `PM_MAX_PARTICLES`），並在文件寫明「4097–16384 粒的陣才會踩到，出貨陣裡沒有這樣的一張」。→ **影響**：若編排者要求可執行的反例，得新增一張 >4096 粒的測試陣（那會動 `assets/`、`SigilHashSpec:178-179` 的 `shippedExamples` 與多份 golden），屬另一個 feature。
- **A4: 委派清單把 §8 的「DLL 約 46 MB」列為過期敘述，實測顯示它是對的。** `dist-newstyle/.../particle-magic-ffi.dll` ＝ 47,896,064 bytes ＝ 45.7 MiB。→ **採取**：**不改數字**，只補量測基準（GHC 9.14.1、Windows `standalone`）。→ **影響**：若編排者堅持要改，唯一誠實的改法是改成「約 46 MiB（47.9 MB）」——純用字，不影響其他任何一項。
- **A5: `examples/unity/` 完全不在 `extra-source-files`（`particle-magic.cabal:40-48` 只列 `examples/c` 與 `examples/haskell`）。** 因此 Unity 三份檔案今天沒有任何出貨或內容守門。→ **採取**：本功能不改變這個現況（把 Unity 檔加進出貨清單屬 F007 的產物內容範疇），改以 `ExampleLoopSpec` 的文字守門涵蓋 T7／T8。→ **影響**：若編排者要求 Unity 範例也進出貨清單，加三行到 `extra-source-files` 即可，但 `ExampleHostSpec` S5 的 `exampleFiles` 只掃 `examples/haskell`，得一併擴寫——那會動到「不動 Haskell 宿主範例」的鄰居，建議留給 F007。
- **A6: `depends-on` 與委派 prompt 指定值不同。** prompt 給 `[F005, F007]`，介面表反推出 `{F001, F005, F007}`（§4.3 兩列消費 F001 新增的常數）。→ **採取**：依「相依性一致性檢查」第 2 條補入 `F001`。→ **影響**：若編排者堅持原值，刪一個 token，內文的「相依性」段第二列同步刪除即可。
- **A7: `docs/integration.md` 檔頭版本沿革（`:15-18`）該由誰加一行。** F007 與本功能都會改這個檔。→ **採取**：由**後落地者**加一行（本功能若在 F007 之後合併就寫 1.4），先落地者不寫。→ **影響**：若兩者同時進整合分支，會在 `:15` 產生一個一行的衝突，人工取兩句合一即可；這是設計上刻意把衝突縮到一行。

## 實作備註

實作於 2026-08-21，前七項（F001–F007）全部已合併之後。設計時記的行號因此全部位移，動手前逐項以錨定字串重新查證；下列是與設計文字不同的地方。

**與文檔的偏差（都在實作自主權內，公開契約零偏離）**

1. **T11 的「§8 平台那一列」改寫成一整列新標題**。原文只說改敘述；實作把該列的標題也從「只有 win64 被完整實測」改為「macOS 沒有任何機器驗過」——舊標題本身就是那句過期敘述，留著標題只改內文會讓表格自相矛盾。F004 動過的「同 handle 不保證順序」那一列一個字都沒碰。
2. **§8 的粒子上限那一列確認不動**（設計 §八已裁定）。委派 prompt 指的「另一列(粒子上限)」與本文件 §八的逐列清點不一致：那一列今天明寫 16384、明寫「請用執行期查詢」，與改寫後的標頭說同一件事，改它只會讓正確的敘述變動。實際過期的是**平台**與**DLL 量測基準**兩列，T11 改的就是那兩列。
3. **不加 `docs/integration.md` 檔頭的版本沿革行**（A7 原訂由後落地者補 1.4）。委派 prompt 的硬性約束「版本號一律由使用者指定，不要自行在文件檔頭掛版本」優先於 A7。F003／F004／F006 也都沒有加，檔頭仍停在 1.3——**要不要補、補成哪個號碼，留給使用者裁決**。
4. **T1／T2 的哨兵詞在兩個檔案有標記差異**。標頭是 `more than PM_MAX_PARTICLES`，`FFI.hs` 是 `more than @PM_MAX_PARTICLES@`（haddock 的行內程式碼標記）。兩條斷言各自釘各自的形式。第一版把哨兵斷在跨行的位置而測試轉紅——散文重新斷行後才綠，這正是「哨兵必須是一個連續字串」的實證。
5. **`main.c` 的註解不得提及 `PM_MAX_PARTICLES`**。T4 的守門是「整份不含該巨集名」，第一版在解釋性註解裡寫了它而轉紅；改成「the header's frozen macro」。守門因此比設計預期更嚴一點，但方向與驗收標準第 2 條一致。
6. **T9 的守門範圍從「章節」收窄為「章節裡的 fenced code block」**。見下方「假綠驗證」。
7. **`SpellRenderer.Update` 在規劃器回非 `PM_OK` 時不 early-return**：記一次 `Debug.LogWarning`、不推進、不寫回累加器，但仍照常 `pm_observe` 與繪製。early-return 會讓該幀整幀不畫，那是設計沒有要求的行為改變。
8. **T13（A8）順手把 `FFI.hs` 的同一句也改了**。標頭與 `FFI.hs:1023` 是同一句已知為假的散文的兩份拷貝；只改一份等於留一份。查證結果：`pm_scene_new` 實際會在三種情況回 NULL——`pm_runtime_ready()` 為假（`cbits/pm_gate.c:383`）、防火牆攔到例外（`FFI.hs` 的 `firewall nullScene`）、註冊表 slot 耗盡（`Registry.hs:204-205`、`registryInsert` 回 NULL word，2³⁰ 個活控制代碼）。新敘述逐條列出這三種並明說實務不可達。

**假綠驗證（逐條變異注入）**

前車之鑑是 F005／F004 各出過一次假綠（取基準時粒子數為零、斷言恆真）。本功能的守門全是文字比對，風險更高，所以對**每一條**新斷言各做一次變異注入：把它宣稱守護的那件事單獨改壞，只跑該條測試，要求它變紅。第一輪 15 條變異中 **T9 是假綠**——「§2.4 含 `pm_plan_steps`」在把程式碼區塊改回手寫累加器之後仍然通過，因為區塊**外面**的散文也提到了規劃器。修法是把斷言收窄到 fenced code block（宿主複製的是程式碼，不是散文），並加上「程式碼區塊內不得出現 `accumulator +=`」。第二輪 18 條變異全部轉紅：

| 變異 | 改壞的東西 | 結果 |
|---|---|---|
| T3-sketch | 標頭 sketch 的 `cap, info, 8` 改回 `PM_MAX_PARTICLES, info, 8` | 紅 |
| T4-macro / T4-leak | `main.c` 容量改回巨集／`free_columns` 少一條 `free` | 紅 |
| T5-loop | `main.c` 改回 `pm_advance(spell, DT)` | 紅 |
| T6-scene | `scene.c` 改回 `pm_scene_advance(scene, DT)` | 紅 |
| T7-ceiling / T7-float | `MaxStepsPerFrame` 改 4／`accumulator` 改回 `float` | 紅 |
| T8-suffix | `PmSmoke` 的 `SetValue` 改回 `0.1f` | 紅 |
| T9-c24 / T9-c42 / T9-cs / T9-list | §2.4、§4.2、§5.4 三個程式碼區塊各自改回手寫累加器；§6 第 5 條刪掉規劃器 | 紅 |
| T10-code | §4.3 的 `PM_ERR_INTERNAL` 改名 | 紅 |
| T11-os | §8 平台那一列改回「只有 win64」 | 紅 |
| T12-cabal | cabal 的 `other-modules` 改掉模組名 | 紅 |
| T1-header / T2-haddock | 標頭與 `FFI.hs` 各自改回 “Today it answers” | 紅 |
| guide-cap | §2.5 的 `16384` 拿掉 | 紅 |

**其他查證**

- 兩支 C 範例以 `clang -Wall -Wextra -fsyntax-only`（GHC 9.14.1 隨附的 mingw 工具鏈）通過，維持 C89 的區塊頂端宣告風格——`packaging/smoke-msvc.ps1` 會拿 `main.c` 去餵 `cl.exe`。
- `ExampleHostSpec` S4 是**行程內**重算，不編譯 `main.c`，所以 `main.c` 的改寫本身不會動 golden；「每幀恰一步」另由 `ExampleLoopSpec` 直接執行 `Magic.Step.plan`（把 `1/60 :: Float` 加寬成 `Double` 後餵給規劃器，斷言 `StepPlan 1 0`）證明，這是全 spec 唯一一條真的跑程式碼的斷言。
- A4 的量測本輪重做：`particle-magic-ffi.dll` ＝ **47,990,272 bytes ＝ 45.8 MiB**（設計時為 47,896,064）。「約 46 MB」仍然正確，依裁定不改數字，只把量測基準寫進該列。
- A3 維持文字守門：16 份出貨陣最大仍是 1742 粒，本輪不新增 >4096 粒的陣。
- `FFIContractSpec` 的 35 個宣告、`PM_ABI_VERSION = 1`、`.def` 的 35 個符號、`BindingContractSpec` 的雙向對帳全部未動且仍綠。

**測試**：`cabal test` → **1864 examples, 0 failures**（基線 1851 ＋ 新增 13：`ExampleLoopSpec` 11 條、`FFIContractSpec` 擴充 2 條）。既有測試零回歸。
