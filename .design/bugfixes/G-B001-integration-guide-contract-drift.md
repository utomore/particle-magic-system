---
id: G-B001
type: bugfix
title: integration-guide-contract-drift
description: 整合指南的決定論承諾與九欄輸出面與凍結標頭脫節
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [adr-0016, adr-0018, ADR-024]
related-feature: []
subsystems: [host-runtime, boundary-host, authoring-engineering]
---

# G-B001: 整合指南與凍結 C ABI 契約脫節

## 症狀

`docs/integration.md` 是非 Haskell 宿主唯一的整合權威（`system.md`「三種消費模式」）。它今天在兩個地方教錯：

**H1 — 決定論的範圍講反了。** L31 對宿主承諾：

> **確定性保證**：同一組 `(JSON, 位置, 面向, seed, dt 序列)` 永遠產生逐位元相同的輸出——同一台機器、**不同平台**、Haskell 路徑或 C ABI 路徑都一樣。

契約權威 `include/particle_magic.h` L187-198 寫的是相反的話：跨平台只保證**結構**（相同粒子、相同順序、相同每幀數量），位置欄可差最後一兩個 bit，實測 windows/linux 最大 1.79e-07。`docs/release.md` L102-115 與 ADR-0016 D4 同。`system.md`「決定論的範圍」明說跨平台逐位元是 **P7** 才升級的目標（ADR-024 確定性三角函數，`particle-simulation` 的 `deterministic-trig` 仍在待展開清單）。

整份 `integration.md` 沒有任何一處補回這個 caveat（`跨平台`／`ulp` 全檔零命中）。

- **影響範圍**：照這句話做 lockstep 連線、跨機器重播或跨平台 golden 比對的宿主會直接踩雷，而且症狀是「偶爾對不上」而不是崩潰——最難查的那一種。

**H2 — 六→九欄的加寬（ADR-0018 / func-spec 0023）沒有進指南。** 標頭與 `Magic.Interface` 都已經加寬，指南停在六欄：

| 對外面 | 契約權威有 | `integration.md` |
|---|---|---|
| `pm_observe_ex`（九欄觀測，速度欄的唯一入口） | ✅ `include/particle_magic.h` L519 | ❌ 零命中 |
| `PM_SHAPE_TRAIL`（= 4） | ✅ 標頭 L286 | ❌ §2.2 形狀表只列到 3 |
| `hasVelocity` / `pbVelX`/`Y`/`Z` | ✅ `Magic.Interface` 匯出 | ❌ 零命中 |
| `fromColumnsWithVelocity` | ✅ `Magic.Columns` 匯出 | ❌ 零命中（§3 只寫 `fromColumns` 的六欄） |

- **影響範圍**：C 宿主照 §2.2 對形狀碼寫 `switch` 會遇到一個指南沒教過的值 4；而拿到 `PM_SHAPE_TRAIL` 批次後要拉伸 quad 需要速度，唯一入口 `pm_observe_ex` 指南沒提過——宿主只能去讀標頭才發現得了。Haskell 宿主同理拿不到 `hasVelocity` 的用法。

## 重現步驟

兩條都是文件↔程式碼的對帳，重現即比對。在專案根目錄：

```sh
# H1：指南承諾跨平台逐位元，標頭與發布政策說結構相同 + 至多 2 ulp
grep -n "不同平台" docs/integration.md          # L31 命中
grep -c "ulp\|跨平台" docs/integration.md        # 0 —— 全檔沒有任何 caveat
sed -n '187,198p' include/particle_magic.h       # 契約權威的相反敘述

# H2：標頭的對外面逐項比對指南（唯二缺口）
for s in $(grep -oE '^[A-Za-z_].*\b(pm_[a-z0-9_]+)\s*\(' include/particle_magic.h \
             | grep -oE 'pm_[a-z0-9_]+' | sort -u); do
  grep -q "$s" docs/integration.md || echo "MISSING entry point: $s"
done            # → MISSING entry point: pm_observe_ex

for m in $(grep -oE 'PM_[A-Z_0-9]+' include/particle_magic.h | sort -u); do
  grep -q "$m" docs/integration.md || echo "MISSING macro: $m"
done            # → MISSING macro: PM_SHAPE_TRAIL
```

對帳結果是 34/35 個進入點、27/28 個巨集已經在指南裡——缺口小而明確，不是整份文件失修。

## 根因分析

`authoring-engineering` 的核心機制是「程式碼裡有事實，文件裡有敘述，測試斷言兩者相等」（`design.md` C3）。這張網今天有一格是空的：

| C3 條目 | 釘住的兩端 | 有測試？ |
|---|---|---|
| C3.6 | 範例與綁定 ↔ 凍結的 C 標頭 | ✅ `BindingContractSpec`（泛用雙向比對，所以 C# 綁定的 `ShapeTrail` 有跟上） |
| C3.1 | 出貨範例的鍵 ↔ 作者手冊 | ✅ `SchemaDocSpec` |
| — | **整合指南 ↔ 凍結的 C 標頭** | ❌ **沒有** |

`test/ExampleLoopSpec.hs` L286 只釘住一個切片——`PM_ERR_*` 必須全部出現在 §4.3；`test/DocContradictionSpec.hs`（host-runtime B001）釘的是**指南與自己**一致，不是指南與標頭一致。所以：

- `func-spec 0023` 加寬到九欄時，改了標頭、改了 `Magic.Interface`、改了 C# 綁定（都有測試逼著改），唯獨指南沒有任何東西逼它改——這就是 H2；
- 決定論那句話是 func-spec 0019／ADR-0016 之前寫的，ADR-0016 D4 裁定跨平台只保證結構之後，`release.md` 與標頭都更新了，指南沒有——這就是 H1。

**兩條是同一個根因**：指南對凍結標頭沒有守門測試，所以它只會愈飄愈遠。這也正是 `authoring-engineering` 自己寫下的「已知盲區」在復發。

## 修復方向

三塊，最小修復：

1. **H1 決定論**：改寫 L31，把「同一台機器逐位元／跨平台結構相同 + 至多 2 ulp」講清楚，並指向 `release.md` 與 ADR-0016 D4；同時點名跨平台逐位元是 ADR-024 的未來目標，避免下一個人又以為現在就有。用語與標頭 L187-198 對齊。
2. **H2 九欄**：§2.1 補速度三欄與 `hasVelocity` 的 opt-in 語意、§2.2 形狀表補 `PM_SHAPE_TRAIL`(4)、新增一小節講 `pm_observe_ex` 與 trail 批次怎麼畫（內容以標頭 L500-518 既有敘述為準，不自創語意）、§3 Haskell 路線補 `fromColumnsWithVelocity`。
3. **守門測試**（根因）：新增 `test/IntegrationContractSpec.hs`，把指南釘在標頭與發布政策上：
   - 標頭宣告的每一個 `pm_*` 進入點都要在指南出現；
   - 標頭定義的每一個 `PM_SHAPE_*` 都要出現在 §2.2 的批次表**裡面**（不是全檔任一處——宿主是照那張表寫 `switch` 的）；
   - **結構斷言**而非比對句子（沿用 `DocContradictionSpec` 的作法）：任何同時談「逐位元」與「跨平台／不同平台」的段落，都必須帶上界線（`ulp` 或「結構」），否則就是 H1 重演。

   剖析器不另寫一份：`FFIContractSpec` 已經匯出 `headerFunctions` / `headerDefines` / `readUtf8`，本 spec 直接 import（house style：標頭剖析器只有一份）。

**不做**：不重寫指南其他章節、不改標頭、不改任何執行期程式碼。本次不動任何 Level 2 公開契約——指南是既有契約的敘述，補的是敘述的缺口。

## TodoList

- [x] T1: 新增 `test/IntegrationContractSpec.hs`（三組斷言）並註冊進 cabal `other-modules`，執行確認**修復前三條全紅**  `dep: -`
- [x] T2: 修 H1——改寫 `docs/integration.md` L31 的決定論段落，與標頭 L187-198／`release.md` 對齊  `dep: T1`
- [x] T3: 修 H2-C 面——§2.1 補速度三欄、§2.2 形狀表補 `PM_SHAPE_TRAIL`、新增 `pm_observe_ex` 與 trail 批次的小節  `dep: T1`
- [x] T4: 修 H2-Haskell 面——§3 補 `hasVelocity` 與 `fromColumnsWithVelocity`  `dep: T1`
- [x] T5: 更新指南檔頭的版本行（版本號由使用者指定）  `dep: T2, T3, T4`
- [x] T6: `cabal test` 全綠  `dep: T2, T3, T4, T5`

## 驗證方式

- `cabal test --test-options='--match "integration guide"'` 三條由紅轉綠；
- 重跑「重現步驟」的兩個 `for` 迴圈，零 `MISSING`；
- `cabal test` 完整套件全綠——特別是既有的 `ExampleLoopSpec`（它也讀同一份指南）與 `DocContradictionSpec` 不得被改動打紅。

## 修復紀錄

**根因一句話**：指南對凍結標頭沒有守門測試，所以它只會愈飄愈遠。修法就是把那格網子補上，再把飄走的兩處拉回來。

**實際修法**

| 檔案 | 改了什麼 |
|---|---|
| `test/IntegrationContractSpec.hs`（新增） | 四條斷言：①標頭宣告的每個 `pm_*` 進入點都在指南；②標頭定義的每個 `PM_SHAPE_*`／`PM_BLEND_*` 連同數值都在 §2.2 的批次表裡；③任何同時談「逐位元」與「跨平台／不同平台」的段落都必須帶界線（`ulp` 或「結構」），並附正向錨點；④標頭與 `release.md` 仍載明容差 |
| `particle-magic.cabal` | 測試 stanza 的 `other-modules` 註冊上述模組 |
| `docs/integration.md` §0 | 決定論改寫成三段：同一台機器逐位元／跨平台只保證結構＋一兩個 ulp（附實測數字與 libm 的理由）／一句話結論與 ADR-0016 D4、`release.md` 的指路 |
| `docs/integration.md` §2.6（新增） | `pm_observe_ex()`、三條可為 NULL 的速度指標、無 `trail` 樣式時填 0 而非回錯、速度的定義與幀率無關性、`PM_SHAPE_TRAIL` 的畫法與退化畫法；Haskell 面的 `hasVelocity` 與 `fromColumnsWithVelocity` |
| `docs/integration.md` §0／§2.2／§3／§8 | 開場補速度欄的指路；形狀表補 `PM_SHAPE_TRAIL`(4)；§3 的 `Magic.Columns` 註解不再寫死「六條裸欄」；§8「四種形狀碼」更正為五種 |
| `docs/integration.md` 檔頭 | 版本 1.5（版本號由使用者指定），1.4 保留在版本歷史 |

**與「修復方向」的偏差**（五處，都往嚴的方向）

1. **守門測試多了第四條**（原計畫三條）：標頭與 `release.md` 必須仍載明容差。這是**反向**的絆線——P7 的 ADR-024 落地、跨平台真的變成逐位元時，容差會從標頭與發布政策消失，這條就會紅，提醒下一個人「指南是第三份副本，要一起改」。沒有它，這次的修復本身會在 P7 之後變成新的過期敘述。
2. **測試自己先有一個 bug**：`normalize` 原本連 `_` 也濾掉（當成 markdown 強調），把 `PM_BLEND_ALPHA` 打斷成永遠比不中的針。第一次執行就紅在這裡，已修並把理由寫進該函數的註解——這正是「先寫測試、先看它紅」的價值：紅的內容不對，就知道測試本身有問題。
3. **結構規則抓到我自己新寫的段落**：改完 §0 之後，第三段「一句話」談了跨平台逐位元卻沒帶界線，被第③條擋下。**改的是文案不是規則**——「凡是提到這個話題就要一併說出界線」正是這次缺陷的形狀，放寬規則等於把缺陷放回來。
4. **刻意不從指南連到 `.design/adr/ADR-024`**：`docs/` 是給宿主看的產品文件，`.design/` 是內部設計樹，出貨文件不該把讀者指進內部文檔。改成直接寫「跨平台逐位元是往後的目標，今天還不成立」，並具體點名 lockstep 與跨機器 golden 這兩個實際用途要注意什麼。
5. **多修了 §8 一行**（原 TodoList 沒有）：「func-spec 0015 起有四種形狀碼」是同一份形狀詞彙的第三份副本，同一個缺陷，一起修才不會下次又靠人眼發現。

**刻意不做**：沒有把 §2.1／§2.5／§5 的「六條」全面改寫成「九條」。`pm_observe()` 回的就是六條，那些敘述是對的；缺的是九欄路徑**在指南裡完全不存在**，所以補的是 §2.6 這條路，不是把既有的路改名。標頭、綁定與任何執行期程式碼一個位元都沒動。

**驗證結果**

- 修復前：`IntegrationContractSpec` 四條中三條紅，分別指名 `pm_observe_ex`、`PM_SHAPE_TRAIL(4)`、以及 §0 那整段決定論文字（測試輸出直接把違規段落印出來）。
- 修復後：四條全綠；`cabal test` **2048 examples, 0 failures**，既有的 `ExampleLoopSpec`、`DocContradictionSpec`、`FFIContractSpec`、`BindingContractSpec` 皆未受影響。
- 「重現步驟」的兩個 `for` 迴圈複跑，零 `MISSING`。

**留給後續的**（本次不做，屬 `/arch-audit system` 同一批發現）

- authoring-engineering 的 `design.md` C3 表應該補一列「整合指南 ↔ 凍結的 C 標頭」，把這次新增的守門測試登記進契約——現在它存在於程式碼但不存在於 Level 2 文檔。
- 同一次檢測還有 M3～M8 六條未處理（子系統循環依賴、時步規劃器歸屬、觀測契約的現在式敘述、公開面敘述過窄、兩支 CLI 缺依賴白名單斷言、`PM_ERR_MANA` 未回填契約）。
