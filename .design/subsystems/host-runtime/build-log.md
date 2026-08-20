---
id: host-runtime-build
type: build-log
title: host-runtime-build
description: 委派展開 host-runtime 階段一：不會崩、可交付
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: host-runtime
---

# 嵌入執行期 委派展開紀錄

## 排程

本次（2026-08-20）只跑**階段一**，閘門停下。階段二的 #9 等 `boundary-host/host-buffer-observe`（它又等 `particle-simulation/host-sink-fill`），#12 等 #9；階段三的 #14 等 `boundary-host/scene-batch-attribution`。跨子系統依賴一律**等**，不照約定先做。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 | W1 | exception-firewall, handle-generation, rts-config-init, step-planner-c-abi, packaging-content | design-done |
| 階段一 | W2 | thread-model（←#2）, oop-load-smoke（←#1, #3）, host-doc-corrections（←#5） | design-done |
| 階段二 | W3 | block-copy-out, diagnostics-stats | 未排 |
| 階段二 | — | host-buffer-observe-c（等 boundary-host）, csharp-native-path（←#9） | 未排 |
| 階段三 | — | cast-many-c-abi, cpp-raii-wrapper 可做；scene-attribution-c 等 boundary-host；csharp-safehandle-il2cpp ←#12 | 未排 |
| 階段四 | — | more-language-bindings（等真實宿主需求） | 未排 |

分支：`feat/host-runtime-p6`（自 `docs/production-grade-architecture` 開出）。checkpoint 以 `git add -A`；開跑前工作樹已清乾淨（`tmp.txt` 刪除、`AGENTS.md` 單獨 commit）。

## 委派決策記錄

契約類的答案已回寫 `design.md`（C1.5、C1.7、C1.9 加 `PM_ERR_STATE`、C2.4 平台降級條款）與 ADR-022 D1／D5，這裡不重複。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 控制代碼的表徵 | 編排者建議：把「索引 ＋ 世代」編碼進不透明指標的**值**裡，宿主永不解參考；不用指向堆積標頭的真指標（釋放後讀取本身就是 UB）。實作者可挑戰，但要在文檔說明理由 | handle-generation, thread-model |
| D2 | out-of-process harness 的形式 | 純 C 程式放 `test/oop/`，由系統 C 編譯器建置；不以 Haskell 程式 dlopen（同進程兩個 RTS）；hspec 只守護它在出貨清單中 | oop-load-smoke |
| D3 | oop 測試的 golden 比對 | 沿用既有平台規則：每幀粒子數全平台斷言、欄位摘要只在參考平台（windows/x86_64）斷言；ADR-024 落地後改全平台 | oop-load-smoke |
| D4 | macOS 產物 | 本輪只寫規格與建置設定；Windows 本機、Linux 用 WSL 驗證；macOS 驗證待 platform-matrix-macos | packaging-content |
| D5 | Windows DllMain 預先啟動 RTS 的處理 | 設計 subagent 先查證；關不掉就走 C2.4 降級條款（capability 數生效、其餘 `PM_ERR_STATE`、文件逐平台明列） | rts-config-init |
| D6 | 模型分配 | **全部 Opus 5,不降級**(2026-08-20 開發者指示)。W1 原本以繼承模型(Fable 5)發出,發現後**立即中止並以 `model: opus` 重發五個**;被中止的三份草稿(F001／F002／F005)移入 scratchpad 的 `fable-drafts/` 保留但不沿用,新 agent 明令禁讀。W2 與所有實作委派同樣 Opus 5 | 全部 |
| D7 | 本次範圍 | 只跑階段一；階段二以後等閘門裁決後再跑（接續模式） | 全部 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| exception-firewall | F001 | F001-exception-firewall.md | opus | opus | design-done |
| handle-generation | F002 | F002-handle-generation.md | opus | opus | design-done |
| rts-config-init | F003 | F003-rts-config-init.md | opus | opus | design-done |
| thread-model | F004 | F004-thread-model.md | opus | opus | design-done |
| step-planner-c-abi | F005 | F005-step-planner-c-abi.md | opus | opus | design-done |
| oop-load-smoke | F006 | F006-oop-load-smoke.md | opus | opus | design-done |
| packaging-content | F007 | F007-packaging-content.md | opus | opus | design-done |
| host-doc-corrections | F008 | F008-host-doc-corrections.md | opus | opus | design-done |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | `pm_age` 攔到例外時的哨兵值 | 回 `-6.0`(非 NaN/0) | — |
| F001 A2 | `pm_occupancy_mask` 的哨兵值 | 回 `0`(fail-safe) | — |
| F001 A3 | out-of-process 觸發防火牆的機制 | 本 feature 不做,交 F006 用 cabal flag 的測試專用符號 | — |
| F001 A4 | `SomeException` 是否含非同步例外 | 全攔、不重拋 | — |
| F001 A5 | 防火牆路徑是否維持 all-or-nothing | 不承諾(宿主緩衝可能半更新);議題屬 F010 | — |
| F001 A6 | 防火牆組合子命名 | `firewall`/`firewallErr`,守門測試靠名字比對 | — |
| F001 A7 | ADR-022 背景寫「30 個 foreign export」 | 實測 29 個;建議修訂敘述 | 接受:改為 29(純敘述修正,已套用) |
| F002 A1 | 控制代碼的 Haskell 面型別 | 維持 `StablePtr`,不改 `Ptr` 新型別 | — |
| F002 A2 | 「不回收識別碼」的解讀 | slot 可回收、控制代碼的值永不重複 | — |
| F002 A3 | **C2.3 與凍結標頭衝突**:7 個符號無錯誤碼通道 | 無法字面成立;建議 C2.3 補「回安全無操作或中性值」 | 接受:C2.3 補「安全無操作或中性值」(已套用) |
| F002 A4 | NULL 與「無效」是否區分 | 區分:NULL 沿用凍結承諾,非 NULL 無效者從 UB 改回 `PM_ERR_ARGS` | — |
| F002 A5 | 世代溢位 | 該 slot 永久退休 | — |
| F002 A6 | 偽造偵測上限 | 恰好等於現存合法控制代碼的字無法辨識,文件明說 | — |
| F002 A7 | 與 F001 的互動 | F001 的 T6 毒化寫法在 F002 後會回 `PM_ERR_ARGS`;建議 F002 先合併 | 接受:實作序改為 F002 → F001 → F003 → F005 → F007 |
| F003 — | **C2.4 的 DllMain 假設被推翻** | 實測 Windows standalone DLL 未在 DllMain 啟動 RTS;三項設定兩平台皆可全生效 | 接受:C2.4／C2.5 與 ADR-022 背景第 7 條已更正 |
| F003 A1 | 三者全生效只能靠 out-of-process 驗證 | in-process 永遠走降級支 | — |
| F003 A2 | `pm_abi_version` 的歸屬 | 改由 C 端回答,使其在初始化前可安全呼叫 | — |
| F003 A3 | 「RTS 由我們啟動」那一支的自動化 | 交 F006 機械化 | — |
| F003 A4 | RTS 統計旗標 `-T` | 本功能不開;F011 需要就得加 `PmConfig` 欄位 | **推翻**:現在就加(已落地為 `PmConfig` 第四欄,佔用初版預留槽,`sizeof` 不變) |
| F003 A5 | `GHCRTS` 環境變數 | 用 `RtsOptsIgnoreAll` 讓它失效(實測 `-A128m` 會殺進程) | — |
| F003 A6 | `PmConfig.size` 大於已知版本 | 一律拒收 | — |
| F003 A7 | `pm_hs_*` 具名符號在 Linux .so 的可見性 | 假設可見,待實作驗證 | — |
| F003 A8 | cbits 的原子實作 | C11 atomics | — |
| F003 A9 | 「要求統計時 `pm_stats` 拿得到 GC 數字」跨兩份文檔,正向路徑 in-process 測不到 | F003 只斷言開關與判準,正向以純 C 探測為證據並於實作期兩平台各跑一次;`pm_stats` 層級的表達由 F011 負責 | 接受;F011 契約卡已補「不可用的表達方式」為其驗收項 |
| F004 A1 | 「單執行緒每次呼叫成本不上升」奈秒級無法字面成立(+6.5 ns) | 改讀作「宿主每幀成本不上升」並提兩條可機械檢查門檻 | 接受;C2.2 與 ADR-022 D4 措辭已同步更正 |
| F004 A2 | 原子讀改寫失敗會**毒化該控制代碼**(現行寫入不會) | 接受並文件化＋測試;後果收斂在單一 handle,與 F001 合併後表現為持續 `PM_ERR_INTERNAL` | 接受 |
| F004 A3 | 註冊表同步原語偏離 F002 接縫的字面建議 | 四個生命週期函數包表級 `MVar` 寫入鎖,**解析路徑維持無鎖**(否則每次推進/觀測都付 take/put) | 接受:F002 的接縫是建議不是契約 |
| F004 A4 | 單核機器無法重現競爭 | 牙齒檢查轉 `pendingWith`,不轉紅 | 接受 |
| F004 A5 | `pm_free` 與同 handle 其他呼叫併發 | 列為「宿主須自行序列化」 | 接受 |
| F004 A6 | 不做 out-of-process 執行緒模型驗證 | 屬 F006／I6 | 接受 |
| F006 1 | 防火牆觸發機制(F001 A3 交辦) | cabal flag ＋ **獨立** foreign-library(預設不建置、檔名不同)＋ 只毒化控制代碼內容物的符號;三方對帳與 C# 對帳零改動,唯一新維護面是鏡像 `.def` | 接受;M8 措辭已補「測試專用建置目標」 |
| F006 2 | golden 是否新錄 | 沿用既有的 Haskell 宿主期望輸出與其容差版平台規則;FNV 摘要先只印為診斷 | 接受 |
| F006 3 | 「還沒修 vs 修好了」如何區分 | 父進程 orchestrator ＋ 子進程 probe;期望值由帶設定的初始化符號是否解析得到決定(不存在⇒PENDING 不計失敗) | 接受 |
| F006 4 | F003 的統計欄位名 | build 腳本 grep 標頭決定;**編排者補充:F003 已定案為 `PmConfig.stats`,常數 `PM_STATS_OFF`／`PM_STATS_ON`** | 接受 |
| F008 A1 | 兩支 C 範例無真實時鐘 | 餵合成經過時間(恰一個固定步長),既有 120 幀 golden 逐位元不變;代價是範例不實際觸發截斷 | 接受 |
| F008 A2 | 單幀最大步數取值 | 取 `8`,依據 demo 外殼既有的同名常數 | 接受 |
| F008 A3 | 無 >4096 粒的出貨陣可當可執行反例(最大 1742 粒) | 改以文字守門(C 最小宿主不得再出現凍結常數)兌現 | 接受:契約卡的「能跑完所有範例陣」今天就已滿足,文字守門更誠實 |
| F008 A4 | 「DLL 約 46 MB」是否過期 | 實測 45.7 MiB,**敘述正確**,只補量測基準不改數字 | 接受(編排者原本誤判它是過期敘述) |
| F008 A5 | Unity 範例不在出貨清單,今天無守門 | 以新 spec 的文字守門涵蓋,不動出貨清單 | 接受 |
| F008 A6 | `depends-on` 與委派指定值不同 | 改為 `[F001, F005, F007]`(錯誤碼表要消費 F001 的兩個新常數) | 接受;功能規劃 #8 的依賴欄已改為 `#1, #5, #7` |
| F008 A7 | 宿主整合指南的檔頭版本沿革 | 由後落地者加一行 | 接受 |
| F002 A8（實作期新增） | slot 空間耗盡（2³⁰ 個同時存活）時建立控制代碼會失敗，理論上與標頭「`pm_scene_new` 絕不回 NULL」牴觸 | 回 `PM_ERR_CAPACITY`／`NULL`；實務不可達、無測試能構造 | 接受；**標頭那句散文由 F008 一併更正**（它本來就負責標頭敘述的準確性） |
| F002 A9（實作期新增） | T8 的「配置量差值為 0」會偶發變紅 | `getAllocationCounter` 以 nursery block 為同步顆粒度，改斷言「20 萬次呼叫總配置 < 65536 位元組且每次 < 128 位元組」，語意不變 | 接受 |
| F001 A8（實作期新增） | F002 合併後 `withCell`／`withScene` 是四參數、毒化改用新建構函式 | 四個帶 guard 的定義以 `where body` 承接 | 接受（純實作自主權，無契約影響） |
| F001 A9（實作期新增） | **改寫了 F002 的 T6 斷言** | 原斷言「例外會從 `pm_age`／`pm_scene_count` 逃出」正是本功能要消滅的行為；改為 `Right (-6.0)` 與 `Right pmErrInternal`，案例意圖保留且更銳利（解析後爆／從未解析／已釋放 → 三個相異值） | 接受：這是正當的測試更新，不是為了讓紅燈變綠 |
| F001 →F005 | 新增符號時的連帶義務 | 新符號必須自行包防火牆，且 `FFIFirewallSpec` 的 `length exports == 29` 守門要同步改成新數字 | 已寫進 F005 的實作 prompt |
| F005 A1 | **C2.6 與凍結標頭衝突**:推進符號是 `void` | 新增 `pm_advance_ex`/`pm_scene_advance_ex`;符號 31→34 | 接受:新增 C1.12,只加推進的兩個 `_ex`,符號 31→34 |
| F005 A2 | 規劃器對非有限/負輸入 | NULL 出參、非有限、`max_steps<0`、`acc_in<0` → `PM_ERR_ARGS`;其餘逐位元鏡射 | — |
| F005 A3 | `_ex` 對 NULL 控制代碼 | 回 `PM_ERR_ARGS` | — |
| F005 A4 | `pm_plan_steps` 是純函數卻需先 `pm_init` | 維持 Haskell 匯出,標頭明文要求;錯誤碼交 F003 的 I3 | — |
| F005 A5 | `plan 1e-300 8 1e300 0` 病態結果 | 逐位元鏡射不修;若判為缺陷應在 boundary-host 開 bugfix | 接受:逐位元鏡射不修;病態案例留待 boundary-host 有需求再開 bugfix |
| F007 A1 | **C4 的 Linux standalone 不可行** | 改「`.so` ＋ 閉包 ＋ `$ORIGIN`」,已在乾淨環境實測通過 | 接受:C4 Linux 列改「`.so` ＋ 閉包 ＋ `$ORIGIN`」(已套用) |
| F007 A2 | `$ORIGIN` 能否穿過 cabal→ld | 未測;允許退回 `patchelf`(WSL 目前沒有) | — |
| F007 A3 | macOS 全未驗證 | `install_name`/雙架構/PIC 皆為紙上設定 | — |
| F007 A4 | 非 git 環境的版本檔 `commit` 欄 | 寫 `unknown` | — |
| F007 A5 | CI windows-latest 有無 `lib.exe` | 腳本以 `vswhere` 探測、退回 `llvm-dlltool` | — |
| F007 A6 | 產物清單的位置與格式 | `packaging/artifacts.json`(JSON,文字合約模式) | — |

## 階段結果

### 階段一

**W1 設計(2026-08-20)**:F001、F002、F003、F005、F007 五份全數產出,共 43 個 Todo,零阻塞,`/arch-audit status` 零不一致。

**提前開閘門的理由**:三條假設牴觸編排者先前寫下的 Level 2 契約(七個符號無錯誤碼通道、Linux standalone 不可行、DllMain 假設被推翻)。依「契約改了受影響的 feature 要重跑」的規則,先實作再改契約等於白做,故在實作前先裁決。

**四項裁決**(見上表):C2.3／C2.6 補措辭並新增 C1.12 推進錯誤碼變體;C4 Linux 改閉包 ＋ `$ORIGIN`;實作序 F002 → F001 → F003 → F005 → F007;`PmConfig` 現在就加 RTS 統計欄位。

**設計是否需重跑**:不需要。F005 與 F007 的文檔本來就是照它們自己查證出的新事實寫的——是設計驅動了契約修訂,不是設計落後於契約。唯一例外是 F003 的 A4 被推翻,該文檔續跑補一項 Todo。

**F003 增量(續跑,非重寫)**:`PmConfig` 第四欄 `stats` 佔用初版預留槽(v1 未出貨,故是改欄位不是加欄位,`sizeof` 不變);新增 T12 與三條 1-to-1 測試。實測發現的陷阱值得記:**不帶 `-T` 時 `getRTSStats()` 不崩,但回半真半假的結構**——`gcs` 與 `allocated_bytes` 是真的,`gc_elapsed_ns` 卻是 `0`,於是「統計關掉」與「真的沒有 GC 暫停」長得一模一樣。唯一誠實的判準是 `getRTSStatsEnabled()`,已釘進標頭供 F011 消費。

**W2 設計(2026-08-20)**:F004、F006、F008 三份產出,階段一八份設計全數完成,零阻塞。

**兩處契約措辭再更正**(皆為編排者先前寫得比實測樂觀):C2.2 的「單執行緒宿主零額外成本」與實測不符(原子讀改寫 +6.5 ns/次推進,對照非原子寫入 2.84 ns),改為「不付鎖的成本、每幀路徑無鎖」;M8 的「只依賴產出的共享函式庫本身」沒涵蓋 F006 的測試專用建置目標,已補。ADR-022 D4 同步。

**實作順序(定案)**:F002 → F001 → F003 → F005 → F007 → F004 → F006 → F008。理由:F002 的註冊表是 F001 毒化測試與 F004 同步原語的地基;F007 必須在 F008 之前,否則宿主整合指南的錨點會位移。

### 實作進度

| # | feature | Todo | 完整 `cabal test` | 編排者獨立驗證 | checkpoint |
|---|---|---|---|---|---|
| 1 | F002 handle-generation | 8/8 | 1797 examples, 0 failures(基線 1788 ＋ 9) | 已重跑,33.2 秒,相同結果 | `70f27b4` |
| 2 | F001 exception-firewall | 8/8 | 1804 examples, 0 failures(＋7) | 已重跑,相同結果 | 見下方 commit |

**F002 的接縫實況**(供後續實作者):註冊表是兩張頂層 `IORef (Table a)`(**非 `MVar`**),解析路徑無鎖;所有變動集中在 `Magic.FFI.Registry` 的 `registryInsert`／`registryRelease`,F004 的表級寫入鎖加在那裡即可,22 個呼叫端不動。`withCell`／`withScene` 現在是四參數(`onNull`／`onInvalid`／續體)。F001 的毒化控制代碼改用 `Magic.FFI` 匯出的 `newSpellHandle`／`newSceneHandle`——`newStablePtr . SpellCell` 已不存在,且那個值現在會被判偽造。

