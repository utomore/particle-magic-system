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
| 階段一 | W1 | exception-firewall, handle-generation, rts-config-init, step-planner-c-abi, packaging-content | in-progress |
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
| D6 | 模型分配 | 全部繼承；host-doc-corrections 設計與實作降 sonnet、step-planner-c-abi 實作降 opus（行為在卡上已寫死） | 見配號表 |
| D7 | 本次範圍 | 只跑階段一；階段二以後等閘門裁決後再跑（接續模式） | 全部 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| exception-firewall | F001 | F001-exception-firewall.md | 繼承 | 繼承 | assigned |
| handle-generation | F002 | F002-handle-generation.md | 繼承 | 繼承 | assigned |
| rts-config-init | F003 | F003-rts-config-init.md | 繼承 | 繼承 | assigned |
| thread-model | F004 | F004-thread-model.md | 繼承 | 繼承 | assigned |
| step-planner-c-abi | F005 | F005-step-planner-c-abi.md | 繼承 | opus | assigned |
| oop-load-smoke | F006 | F006-oop-load-smoke.md | 繼承 | 繼承 | assigned |
| packaging-content | F007 | F007-packaging-content.md | 繼承 | 繼承 | assigned |
| host-doc-corrections | F008 | F008-host-doc-corrections.md | sonnet | sonnet | assigned |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| （W1 設計回報後填入） | | | |

## 階段結果

### 階段一

（進行中）
