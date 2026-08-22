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
| F003 A10（實作期新增） | T12 的「要求統計但開不起來 → `PM_ERR_STATE`」**in-process 不可達**（hspec 套件自己以 `-T` 建置，統計本來就是開的） | 改斷言錯誤碼表的另一列＋「旗標初始化後永不改變」；降級條款本身仍由同呼叫的 nursery／GC 觸發 | 接受；**缺口指派給階段二的 F011**（它擁有 `pm_stats`，隨它補一個小型 Haskell 宿主覆蓋「RTS 已起但沒 `-T`」那一支） |
| F003 A11（實作期新增） | 併發初始化的斷言方式 | 改為兩執行緒**要求不同 capability 數**、斷言事後值恰為其一（證明只有一個真的碰到 RTS）；`PM_OK` 路徑由兩平台的純 C 探測覆蓋 | 接受：in-process 首次初始化必走降級支，原斷言不可能成立 |
| F003 →F005 | 新符號的雙重義務 | 新等式 `foreignExportSymbols ≡ pm_hs_ ＋ (headerFunctions \ 三個 lifecycle)` 不寫死清單：F005 的三個新符號要同時加 `pm_hs_*` 匯出名**與** `cbits/pm_gate.c` 的閘門包裝，漏一個就紅 | 已寫進 F005 的實作 prompt；F005 三重義務全數履行 |
| F005（實作期發現） | **自己的測試出現假綠** | 場景版「狀態不變」原本只推進 3 幀取基準，ring-fire 當時一顆粒子都沒有，「前後相同」變成恆真；改為推進 40 幀並加 `liveParticles > 0` 防呆後才有效 | 接受：這是委派模式下最該被抓到的一類問題，執行者自己抓到並修掉 |
| F005（實作期發現） | 文檔 T6 寫「符號 31 → 34」算漏了 F003 的 `pm_init_ex` | 實際基線是 32，改動後 35 | 接受；**ADR-022 的同一處數字（編排者寫的）已一併更正為 31 → 35** |
| F005 A5 | `Magic.Step.plan` 的病態案例：有限輸入下比值溢位 → 積壓爆表反而回 0 步 | C 面逐位元鏡射不修 | **已結案**:由 `boundary-host/B001` 修復,C 面是轉呼不是複製,自動跟著正確 |
| F007 A2（結論反轉） | `$ORIGIN` 能否穿過 cabal→ld | 穿得過，**但 cabal 自己在前面寫了 46 條絕對路徑**，`$ORIGIN` 排第 47，於是「自不自足」在開發機上無法回答。`-fno-use-rpaths` **實測無效**（那些條目是 cabal 加的不是 GHC），已從 cabal 檔移除、註解改寫成實況；改由 `pack.sh` 重寫打包後那一份的 RUNPATH | 接受：執行者推翻自己先前的設計假設並留下實測依據 |
| F007 A7（實作期新增） | 工作樹是 CRLF，而 CRLF 的 shell script 在 POSIX shell 是語法錯誤 | 新增**最小範圍**的 `.gitattributes`：只有 `*.sh text eol=lf` 一行，刻意不寫 `* text=auto`，其餘檔案的換行行為完全不變 | 接受：範圍克制且理由寫在檔案註解裡 |
| F007 A8（實作期新增） | 無 patchelf 時如何縮短 RUNPATH | `pack.sh` 就地縮短字串（chrpath 的作法）；同時處理 `DT_RPATH` 但**只實測過 RUNPATH** | 接受 |
| F007 A9（實作期新增） | 閉包檔數隨相依解析而變（本輪 68 個） | 清單以 glob `*.so*` 表達 | 接受；若 release-artifacts 要逐檔比對，屆時請 `pack.sh` 另吐實際清單 |
| F004（實作期發現） | **同一個假綠陷阱又出現一次** | 首版寫成「每執行緒 1000 步」，法術年齡只有 0.12 s、ring-fire 此時沒有粒子，逐位元比對會退化成兩個空 buffer；改為固定總步數 8192（恰好 1.0 s、2049 粒），且每次逐位元比對前先斷言存活粒子 > 0 | 接受：F005 踩過同一個坑，經由 prompt 傳遞後被 F004 自己攔下——這條經驗要留在紀錄裡 |
| F004（量測更新） | C2.2 括號內的成本數字 | 實作後重測為單執行緒 +6.0 ns、8 執行緒 +8.8 ns（設計期估 +6.5 ns），仍在「個位數奈秒」內 | 接受；**C2.2 與 ADR-022 D4 的數字已更新為兩個實測值** |
| F006 A12（實作期新增） | F002 落地後控制代碼已是註冊表索引，原毒化寫法失效 | 毒化符號改為交出「內容物為 bottom 的**全新**合法控制代碼」；比原案多一條更強的證據——毒化前施的法術在毒化後仍跑得動 | 接受 |
| F006 A13（實作期新增） | **F003 A10 的缺口在 Linux 上已關閉** | 新增第八個 probe：以 dlsym 的 `hs_init` 先起 RTS 再呼叫 `pm_init_ex`，斷言標頭逐平台表的最後一列，Linux PASS；Windows 不匯出 RTS 符號故 SKIP | 接受；**Windows 那一半仍留給階段二的 F011** |
| F006 A14（實作期新增） | harness 的必需符號表會落後於出貨面 | 加第五條 hspec 守門：`REQUIRED_SYMBOLS` ≡ 出貨 `.def`（出貨面已從 31 長到 35） | 接受 |
| F006（反向驗證） | 假綠防治 | **兩平台各跑七種變異注入**：整數欄差 1、checksum 大幅偏離、末位差 1（Windows 紅／Linux 綠，證明容差分支在做事）、golden 截短、**強制粒子數歸零（F004／F005 踩過的那個形狀）**、rts-config 錯值、firewall 改餵健康控制代碼——全部如預期變紅；五條 hspec 守門也逐條注入變紅 | 接受：這是階段一最徹底的一次反向驗證 |
| F008（實作期發現） | **第三次抓到假綠** | 首輪 15 條變異注入中，「§2.4 含 `pm_plan_steps`」在把程式碼區塊改回手寫累加器後**仍然通過**——區塊外的散文也提到規劃器。收窄為「fenced code block 內含 `pm_plan_steps` 且不含 `accumulator +=`」後，第二輪 18 條全數轉紅 | 接受：文字守門的假綠形狀與程式碼守門不同，但同樣要注入驗證 |
| F008（推翻編排者的指示） | 編排者在 prompt 裡說「§8 要改的是粒子上限那一列」 | 逐列查證後**不符**：那一列今天已明寫 16384 與「請用執行期查詢」，與改寫後的標頭一致，確認不動；實際過期的是**平台覆蓋**與 **DLL 量測基準**兩列 | 接受：執行者查證後推翻編排者的指示是對的 |
| F008 A4（重新量測） | DLL 大小 | 本輪實測 47,990,272 bytes = **45.8 MiB**（設計期 45.7），「約 46 MB」仍正確 | 接受：依裁定不改數字，只補量測基準 |
| F008 A7（**待使用者裁決**） | 宿主整合指南檔頭的版本沿革要不要補 | **未加**——全域規則「版本號一律由使用者指定」優先於 A7 的「後落地者補 1.4」；檔頭仍停在 1.3，F003／F004／F006 也都沒加 | **懸而未決:要不要掛版本、掛哪個號碼,只有使用者能決定** |
| F005 A1 | **C2.6 與凍結標頭衝突**:推進符號是 `void` | 新增 `pm_advance_ex`/`pm_scene_advance_ex`;符號 31→34 | 接受:新增 C1.12,只加推進的兩個 `_ex`,符號 31→34 |
| F005 A2 | 規劃器對非有限/負輸入 | NULL 出參、非有限、`max_steps<0`、`acc_in<0` → `PM_ERR_ARGS`;其餘逐位元鏡射 | — |
| F005 A3 | `_ex` 對 NULL 控制代碼 | 回 `PM_ERR_ARGS` | — |
| F005 A4 | `pm_plan_steps` 是純函數卻需先 `pm_init` | 維持 Haskell 匯出,標頭明文要求;錯誤碼交 F003 的 I3 | — |
| F005 A5 | `plan 1e-300 8 1e300 0` 病態結果 | 逐位元鏡射不修;若判為缺陷應在 boundary-host 開 bugfix | **已結案**:由 `boundary-host/B001` 修復,C 面是轉呼不是複製,自動跟著正確 |
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
| 2 | F001 exception-firewall | 8/8 | 1804 examples, 0 failures(＋7) | 已重跑,相同結果 | `04ec6ad` |
| 3 | F003 rts-config-init | 12/12 | Windows 1816 examples 0 failures(＋12);Linux(WSL)1816 examples 0 failures 9 pending | 已直接執行 spec 二進位重跑,38.9 秒,相同結果 | `3dba002` |
| 4 | F005 step-planner-c-abi | 8/8 | 1831 examples, 0 failures(＋15) | 已重跑,39.9 秒,相同結果 | `80fe58d` |
| 5 | F007 packaging-content | 8/8 | 1838 examples, 0 failures(＋7) | 已重跑,32.9 秒,相同結果;`dist/` 確認已忽略 | `eed790e` |
| 6 | F004 thread-model | 8/8 | 1846 examples, 0 failures(＋8) | 已重跑,41.2 秒,相同結果 | `66bbe06` |
| 7 | F006 oop-load-smoke | 12/12 | 1851 examples, 0 failures(＋5);out-of-process:Windows 5 pass／3 skip、Linux 7 pass／1 skip(毒化庫 6／8 pass) | 已重跑,41.1 秒,相同結果;確認毒化庫是 flag 開關、預設不建置 | `0b6c166` |
| 8 | F008 host-doc-corrections | 13/13 | 1864 examples, 0 failures(＋13) | 已重跑,37.6 秒,相同結果;標頭 35 個宣告、`PM_ABI_VERSION` 仍為 1 | 見下方 commit |

**階段一實作全數完成**:8 個 feature、75＋ Todo、測試自基線 1788 增至 **1864 examples, 0 failures**,每一步都由編排者獨立重跑驗證。`PM_ABI_VERSION` 全程未動,符號自 31 增至 35(全部加法)。

### 階段一閘門:`/arch-audit subsys host-runtime`

**狀態掃描**:零架構／子系統不一致,8 個 feature 全 done,契約卡 17/17,進度 8/17(47%)。

**五個風險點逐一查證為真**:`PM_ABI_VERSION` 未動且 31 個凍結宣告**零修改**(集合 diff 對 host-runtime 前最後一個 commit,差集純為 4 個新增);防火牆覆蓋全部 32 個匯出(原始碼稽核逐定義區塊比對,閘門覆蓋率是**計算**而非寫死);註冊表解析路徑確實無鎖;毒化 flib 有**四層防護**(flag `default: False` ＋ `manual: True` ＋ `buildable: False` ＋ 檔名不同),`.def` 差集雙向驗證恰為單一符號;`docs/integration.md` 的 53 處 `§` 引用與 10 個錨點全部可解析。

**邊界外洩:無。** `src/ffi` 零 `magic-core` import,白名單斷言仍然有效,內部型別只在 `other-modules` 的 Internals 區。**I1–I6 全數遵守,簽名無漂移**;C# 綁定 35 個 `extern` ≡ 標頭 35 個宣告。

**發現(依嚴重度)**:

| # | 嚴重度 | 內容 | 去向 |
|---|---|---|---|
| 1 | **高** | `docs/integration.md` 三處仍在教已被本輪推翻的契約(`:647`／`:866` 的「一個 handle／scene 一個執行緒、庫內無鎖」、`:902` 的「shutdown 之後不能再 init」);**而且守門測試是假綠**——兩條 reject 比對字面字串,`:866` 少了「屬於」、`:647` 多了「仍然」,雙雙漏網。F008 文檔自己寫明 `:902` 那列歸 F003 改,結果沒改到 | `/bugfix` |
| 2 | **高** | `cbits/pm_init.c:292` 降級路徑對 `capabilities == 0` **靜默丟棄**:標頭把 0 定義為「依硬體」且那正是歸零結構的預設值,但該請求既不套用也不計入 `PM_ERR_STATE`,違反 C2.4「不靜默忽略任何無法生效的設定」 | `/bugfix` |
| 3 | 中 | 契約卡 `thread-model` 的驗收標準仍寫「壁鐘對照」,與閘門修訂後的 C2.2 矛盾(實際交付的 T7 量的是配置量)——**下一次委派會照著錯的驗收標準做** | `/subsys-design` 更新 |
| 4 | 中 | `Magic/FFI.hs` 1825 行,M3 三分之二的職責(防火牆、原子步)住在 M2 的檔案裡,M3 在檔案系統上並不完整存在 | `/enhance-design` |
| 5 | 中 | 資料流管線圖**完全沒有 I3 的 RTS 就緒閘門**(它其實是每個符號的第一段),且把驗證畫在防火牆之前而程式碼是相反的巢狀——**該改的是文檔,程式碼的排法較好** | `/subsys-design` 更新 |
| 6 | 中 | C1 要求的「標頭決定論註記改寫為跨平台逐位元」**沒有任何 feature 擁有**,且在 `particle-simulation/deterministic-trig`(P7)落地前寫進去就是謊話 → 契約懸空 | `/subsys-design` 更新 |
| 7–13 | 低 | 標題層級不一致(§4.4.1／§4.4.2 用 `###`)、檔頭 frontmatter 的 `updated`／`related-*` 未補、`pm_scene_cast*` 閘門路徑不寫 `*out_id`(與 Haskell 路徑不一致)、cabal 註解宣稱「恰三處差異」不實、白名單守門未覆蓋毒化 stanza、兩處交叉引用失效(**原生問題非本輪造成**) | `/bugfix`／`/enhance-design` |

**抽象邊界(檢查 5)**:C2.2／C2.4／C2.5／C4 裡的實測敘事括號屬 Level 2 越界——那些是 build-log 與 ADR 的內容,建議清掉。**這是編排者在閘門修訂契約時寫進去的**。

### 閘門後的修復(使用者裁決:先修兩條高的再進階段二)

| id | 缺陷 | 結果 |
|---|---|---|
| `host-runtime/B001` | 整合指南三處教錯契約 ＋ **守門假綠**(reject 比對字面字串,新散文多「仍然」少「屬於」就漏網) | 守門改為三層:正規化後比對語意片段、結構性斷言(「無鎖」前四字必須是「每幀路徑」——錯的是範圍不是用詞)、正向錨點釘住權威敘述。**六個變異全紅**,含一個從沒人寫過的第三種說法。順帶掛版本 1.4 與 frontmatter |
| `host-runtime/B002` | `capabilities == 0` 在降級路徑被靜默丟棄 | 採「當真實請求套用」而非回錯誤碼——該列的 capability 數**辦得到**,回 `PM_ERR_STATE` 等於謊報,且會讓每個照建議寫法歸零 `PmConfig` 的宿主都收到錯誤。非降級路徑一併查證(對 0 寫 `-N`),兩條路徑同源。Linux out-of-process 探針補 end-to-end |
| `boundary-host/B001` | `Magic.Step.plan` 有限輸入下截斷護欄失效 | **根因比原述更廣**:護欄被放在已失去資訊的量上(`floor :: Double -> Int` 在 Int 值域外不飽和),所以病態域是「比值離開 Int 值域」而非「溢位成 Inf」;`-O2` 下會回**負步數**,累加器也會被 `Infinity` 毒化。判斷移到 `floor` 之前,證明對所有落在 Int 內的比值恆等 → 合法輸入逐位元不變(等價律 3000 組、不變式 20000 組) |

**第四次假綠,也是最細的一次**:`boundary-host/B001` 的變異注入把判斷式改成差一的 `ratio > maxSteps`,**第一次全綠**——它的逐位元保護測試缺了「`n` 恰等於 `maxSteps` 且有餘額」那一列。補四列邊界後才如預期變紅。教訓寫進文檔:逐位元保護測試只挑典型輸入時,擋得住「功能被拆掉」的變異,擋不住「邊界被挪半步」的變異,而後者才是修改真正的風險面。

**環境問題**:三個 bugfix agent 共用同一個 `dist-newstyle`,撞到 Windows 的 `spec.exe.manifest` 刪除競態,也讓彼此在對方紅燈期間看到假失敗(兩個 agent 都正確辨識出「那不是我的檔案」)。**日後平行跑實作類 agent 要考慮這一點。**

**修復後全套驗證**(編排者獨立重跑):`cabal build all` 綠、`cabal test` **1879 examples, 0 failures**、`PM_ABI_VERSION` 仍為 1、35 個宣告、`docs/integration.md` 掛 1.4。

**尚未處理的開放項**

**F007 的執行中斷**:第一次委派在寫守門測試時被 watchdog 判定停滯(600 秒無串流進展)而中止,**不是判斷或阻塞問題**。編排者盤點後發現:建置已綠、`.gitattributes` 與 `packaging/` 四支腳本都在,唯一的紅是 `test/PackagingSpec.hs` 兩處 lambda 少了反斜線(其餘 13 個正常,孤立手滑),另有 46 MB 的 `dist/` 產物未被忽略、文檔 8 個 Todo 未勾。以 SendMessage 續跑同一個 agent 收尾,未重寫。

**F002 的接縫實況**(供後續實作者):註冊表是兩張頂層 `IORef (Table a)`(**非 `MVar`**),解析路徑無鎖;所有變動集中在 `Magic.FFI.Registry` 的 `registryInsert`／`registryRelease`,F004 的表級寫入鎖加在那裡即可,22 個呼叫端不動。`withCell`／`withScene` 現在是四參數(`onNull`／`onInvalid`／續體)。F001 的毒化控制代碼改用 `Magic.FFI` 匯出的 `newSpellHandle`／`newSceneHandle`——`newStablePtr . SpellCell` 已不存在,且那個值現在會被判偽造。

