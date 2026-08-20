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
| 階段一 | W2 | thread-model（←#2）, oop-load-smoke（←#1, #3）, host-doc-corrections（←#5） | pending |
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
| thread-model | F004 | F004-thread-model.md | opus | opus | assigned |
| step-planner-c-abi | F005 | F005-step-planner-c-abi.md | opus | opus | design-done |
| oop-load-smoke | F006 | F006-oop-load-smoke.md | opus | opus | assigned |
| packaging-content | F007 | F007-packaging-content.md | opus | opus | design-done |
| host-doc-corrections | F008 | F008-host-doc-corrections.md | opus | opus | assigned |

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
| F003 A4 | RTS 統計旗標 `-T` | 本功能不開;F011 需要就得加 `PmConfig` 欄位 | **推翻**:現在就在 `PmConfig` 加 RTS 統計欄位(C1.5 已補);F003 文檔需補一項 Todo |
| F003 A5 | `GHCRTS` 環境變數 | 用 `RtsOptsIgnoreAll` 讓它失效(實測 `-A128m` 會殺進程) | — |
| F003 A6 | `PmConfig.size` 大於已知版本 | 一律拒收 | — |
| F003 A7 | `pm_hs_*` 具名符號在 Linux .so 的可見性 | 假設可見,待實作驗證 | — |
| F003 A8 | cbits 的原子實作 | C11 atomics | — |
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

