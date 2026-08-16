---
id: adr-0016
type: adr
title: release-compatibility-policy
status: accepted
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0005, adr-0006, adr-0011]
related-spec: [func-0019]
---

# ADR-0016：發布與相容性政策——平台分級、版本語意，以及決定論的真實範圍

- 狀態：已採納（2026-08-16）
- 相關：[func-spec 0019](../spec/func-0019-engineering-ci-release.md)（落地）、[docs/release.md](../release.md)（流程本文）；ADR-0011 D7／D8（C 合約與跨界決定論）、ADR-0005（JSON 可攜性）、ADR-0006（SoA 六欄）
- **本 ADR 修訂 ADR-0011 D8 的宣稱範圍**（見 D4）

## 背景

十八輪 spec 全部靠一台 Windows 機器上的一次手動 `cabal test` 判定「這個 commit 是好的」。roadmap §3.5 為此記了三筆未記帳的欠款：CI、release tag／版本發布流程、「只有 win64 實測過」。0014 交付 `magic-validate`（exit code ＝ 失敗檔數）之後，第三個 CI 步驟降到一行，門檻已經沒有理由再拖。

真正需要**決策**而不只是設定的有三件事：哪些平台算數、版本號代表什麼、以及——這是本輪最貴的一個發現——**「決定論」這句話到底涵蓋多大範圍**。

前兩件是政策；第三件是 0019 S2 第一次在 win64 之外跑整套測試之後，被實測逼出來的。

## 決策

### D1（支援平台分級）

| 級別 | 意義 | 成員 |
|---|---|---|
| **Tier 1** | 進 main 之前由 CI 驗證 build＋test＋validate（觸發時機見 D5）；回歸視為缺陷 | `windows-latest`（x86_64）、`ubuntu-latest`（x86_64） |
| **Tier 2** | 預期可用但無 CI；壞了修，但不擋發布 | macOS、其他 Linux 發行版 |
| **未支援** | 沒有人試過 | ARM、WASM、行動平台 |

分級與 CI 矩陣**必須**一字相同，由 `test/ReleaseDocSpec.hs` 三向守護（`docs/release.md` ≡ `README.md` ≡ `.github/workflows/ci.yml`）。分級是**承諾**，不是願望：一個平台進 Tier 1 的唯一方式是它出現在 CI 矩陣裡。

### D2（版本語意）

- 套件版本（cabal `version:`）遵循 PVP，四段。`magic-core`／`magic-boundary` 是 `visibility: public` 的公開子庫，外部專案會直接 `build-depends` 它們——**凍結介面的破壞性變更 ⇒ major bump**（前兩段其一）。
- 所有 `build-depends` 條目帶 `^>=` 上界，由 `test/ReleaseMetaSpec.hs` 全 stanza 掃描守護。同套件內的子庫依賴（`particle-magic:magic-*`）豁免——它們的版本恆等於本套件自身。
- `tested-with:` 宣告**實際建置並測試過**的 GHC，且必須 ≡ CI 安裝的版本（`ReleaseMetaSpec` 與 `CIWorkflowSpec` 從兩端各釘一次）。
- tag 格式 `v<version>`，四段與 cabal 版本一字相同（`v0.1.0.0`）。tag 是目前唯一的發布動作。

### D3（`PM_ABI_VERSION` 與套件版本獨立遞增）

兩個世代號**互不代表對方**。理由是它們守護的東西不同：header 是 add-only（ADR-0011 D7），加宣告不動 ABI 世代；而 Haskell 面的破壞性變更完全可能不碰 C 面，反之亦然。把兩者綁在一起只會逼出假的 bump——0012 把粒子上限從 4096 抬到 16384 而 header 一個字元沒動，就是這件事的實例。

**`PM_ABI_VERSION` 只在 header 出現非加法變更時 +1**，而那正是 add-only 規則被打破的時刻——所以這個世代號同時是規則的計數器。

### D4（決定論的範圍：**同平台逐位元，跨平台結構相同 ＋ 位置欄兩個 ulp**）

**這是本輪唯一被實測改寫的決定，也是 CI 換來的東西。**

ADR-0011 D8 的條文是「FFI 路徑 ≡ Haskell 路徑」，那是同一個行程內的等價律，**本輪實測未動搖它**。被推翻的是它被引申成的那句話——`include/particle_magic.h` 檔頭原本寫著輸出 bit-identical「**on every platform**」。

0019 S2 在 Debian 13 / GHC 9.14.1 / x86_64 上第一次跑完整套測試（1156 examples，與 win64 同數字），結果：

- **23 條逐位元 golden 紅**：`Acceptance10Spec` 8、`FieldPlumbingSpec` 7、`PerfGoldenSpec` 8。其餘 1133 條全綠，含 `ExprGoldenSpec` 與 FFI 跨界等價律。
- 逐欄位比對兩平台的原始位元（12 個範例陣 × 40 幀 × 六欄，每欄 100 164 個值）：

  | 欄 | 相異數 | 最壞 ULP |
  |---|---|---|
  | `pbPosX` | 1183 / 100164 | 8 |
  | `pbPosZ` | 1274 / 100164 | 289 |
  | `pbPosY`／`pbSize`／`pbLife`／`pbColor` | **0** | 0 |

  最大**絕對**差 `1.79e-07`（約 1.5 個 1.0 的 ulp）；最大相對差 `2.9e-05`，發生在一個接近零的值上（消去誤差放大既有的最後一位差異，不是新的誤差來源）。`pbPosY` 全同是因為量測用的 `casterFacing = V3 0 1 0`——三角函數只落在 X／Z 兩軸。

- **根因直接量測，非推論**：對 4096 個 `Float` 角度逐點比較 `sin`／`cos`，**sin 63/4096 相異、cos 46/4096 相異，最壞都是 1 ulp**。IEEE-754 保證 `sqrt` 正確捨入，**不保證** `sin`／`cos`——mingw 的 libm 與 glibc 的都合法。這不是本專案的算術問題，也沒有未定義行為。

於是 §2.1 的三條裁決路徑走第二條，決定如下：

1. **逐位元決定論的範圍收窄為「同一平台上」**。這是重播、回歸網、FFI 等價律真正倚賴的東西，全部不受影響。
2. **跨平台的保證是結構**：相同的粒子、相同的順序、相同的每幀數量，位置欄相差至多兩個 ulp（實測絕對值 ≤ `1.79e-07`）。
3. 機械化方式：**golden 的摘要半場只在錄製它的平台上斷言，平台無關的半場（每幀粒子數）到處斷言**（`test/GoldenPlatform.hs`）。golden 檔零重錄——重錄只會斷言「這台機器同意它自己」。`FieldPlumbingSpec` 的歷史基線是整段 80 步走訪的單一摘要，旁邊沒有可退守的逐幀結構，故在非參考平台報 pending 而非改寫。
4. `include/particle_magic.h` 檔頭那句話改寫為上述範圍。**這是註解變更，不是宣告變更**——ADR-0011 D7 的 add-only 約束的是宣告與版面，且合約檔上留著一句已知為假的話，比修正它更違背 D7 的用意。ABI 世代**不 +1**（D3）。
5. README 的兩處決定論措辭同步收窄。

**新增參考平台的成本**：錄一份該平台的 golden，並放寬 `referencePlatform`。三個 golden spec 的其他部分不動。

### D5（CI 的觸發時機：**閘門設在併入 main，不是設在每次 push**）

本 repo 是 **private**，所以 GitHub Actions 的分鐘數會計費（Free 方案含 2,000 分鐘／月），而且 **Windows runner 以 2× 計費、Linux 1×**。這使「什麼時候跑」變成預算決定，不是細節。

實測基礎上的估算（含 setup）：

| | Linux | Windows（2×） | 單次矩陣 |
|---|---|---|---|
| 冷快取（h-raylib 從頭編 raylib 的 C 原始碼） | ~20 分 | ~40 分 | **~60 計費分** |
| 熱快取 | ~5 分 | ~10 分 | **~15 計費分** |

因此：

- **`pull_request` 到 `main`**——閘門設在真正的決策點。日常在分支上推進度不花錢，那個階段由開發者自己的 `cabal test` 覆蓋（本輪之前十八輪都是這樣做的，而且有效）。
- **`push` 到 `v*` tag**——把 `docs/release.md` §4 第 3 步（「CI 兩平台全綠」）從「人記得跑」變成機器保證。一年幾次。
- **`workflow_dispatch`**——不開 PR 也想跑一次時的入口。
- **不設分支 push 觸發。** 除了成本，它與 `pull_request` 併用時會讓 PR 分支的每一次 push **跑兩遍同樣的工作**，買不到任何東西。`CIWorkflowSpec` 明文斷言它不存在——重新加回來必須是一個決定，不能是一次手滑。

**兩個平台都留在矩陣裡。** 砍掉 Windows 可以省一半帳單，但 Windows 是**參考平台**——D4 的逐位元 golden 只在它上面被斷言，Linux 那份只剩每幀粒子數。省掉它等於把本輪最強的守護關掉，方向錯了；正確的省法是降低**跑的次數**，不是降低**每次跑的強度**。



**正面**：

- 「這個 commit 是好的」不再依賴某一台機器，而且是在**兩個作業系統、兩條連結路徑**上被驗證——Windows 走 `.def` 匯出清單，Linux 走 GHC 預設匯出的 `.so`，後者從 0009 至今從沒被驗過。
- 專案對外的最強宣稱從此有實測邊界，而不是一句沒人檢查過的形容詞。宿主拿得到具體數字（`1.79e-07`）去決定自己要不要在意。
- `magic-validate` 進 CI，資產退化（手改 JSON 改壞）從此在 push 當下被抓。
- 版本、tag、平台分級三者互相釘死，任何一邊漂移都會在 `cabal test` 就紅。

**負面**：

- **跨平台重播不再是逐位元的**。任何倚賴「錄影檔在另一台機器上逐位元重現」的用法（跨機錄影比對、跨平台的 golden 影像測試）必須改用容差比較。同機重播不受影響。
- 逐位元回歸網在非參考平台上只剩結構強度——Linux CI 抓得到「粒子數變了」，抓不到「某顆粒子位移了 1 ulp」。參考平台的那份仍然逐位元，所以這個洞不會讓回歸溜過整個 CI，只會讓它在 Windows job 才現形。
- `FieldPlumbingSpec` 在非參考平台留下 7 個 pending。pending 不是綠，也不假裝是。
- CI 冷快取很慢（h-raylib 每次從頭編 raylib 的 C 原始碼）。以 cabal store ＋ `dist-newstyle` 快取緩解，key 取套件描述＋解析後的 plan。

## 被否決的替代方案

- **重錄「ULP 容差版」golden**（§2.1 第二條路的字面讀法）：要把摘要換成量化值或原始欄位。量化的邊界值可能在兩個平台落到不同格，**CI 會偶發紅**——用一個 flaky 測試換取一個更弱的斷言，兩頭皆輸。存原始欄位則是每個範例陣約 2 MB 的 golden。
- **Linux 不跑 `cabal test`**（只 build＋validate）：既有測試模組零觸碰，但等於放棄本 spec 最主要的價值。跨平台驗證的重點正是那 23 條。
- **把 `sin`／`cos` 換成自製的正確捨入實作**：可以讓逐位元跨平台成立，代價是熱路徑上最貴的兩個函數換成慢好幾倍的版本（0010 把取樣常數因子壓到 65 ns/粒，這會直接吐回去），換到的是一個沒有任何宿主要求過的保證。若日後真有「跨機逐位元」的需求（網路對戰同步、跨平台錄影驗證），這是正解的所在地，屆時另開一輪。
- **調大 golden 的容差直到綠**（§2.1 第三條路的誤用）：差異若是結構性的，調容差是掩蓋；本輪已量到它是 1 ulp 級，才有資格收窄而不是掩蓋。這兩者的差別是量測，不是判斷。
- **把套件版本與 `PM_ABI_VERSION` 綁定**：見 D3，會逼出假的 bump。
- **每次 push（所有分支）都跑 CI**（本輪初版即如此，交付當天由使用者指出並改掉）：private repo ＋ Windows 2× 倍率下，熱快取每次 push 約 30 計費分鐘（`push` 與 `pull_request` 各跑一遍），2,000 分鐘的月額度約 60–70 次 push 就見底，冷快取更快。以本專案每輪 spec 數十次 commit 的節奏，這個設計會在第一個月內撞牆。**教訓**：CI 的觸發條件是成本決定，設計時要把帳算出來，而不是照抄「on: push」的預設姿勢。
- **從矩陣移除 Windows 以省 2× 帳單**：Windows 是 D4 的參考平台，逐位元 golden 只在它上面被斷言。降低每次跑的強度換帳單，方向錯了——正確的省法是 D5 的「降低跑的次數」。
- **改用 self-hosted runner**（開發機同時有 Windows 與 WSL Debian，恰好就是兩個 Tier 1 平台，且 GitHub 對 self-hosted 不計分鐘）：帳單為零且快取永遠是熱的，但要求該機器常駐開機並維護 runner 服務，關機時 CI 直接排隊。POC 階段不值得這個維運面；若日後 CI 頻率提高，這是第一個該重新評估的選項。
- **macOS 進 Tier 1**：GitHub 的 macOS runner 貴（10× 倍率），且 h-raylib 在其上的建置未驗過。等有實際需求（D1 的 Tier 2 就是為此存在）。
- **上 Hackage／自動 release**：上 Hackage 是對 API 穩定度的承諾，本專案仍是 POC（roadmap §6）。tag 讓 `source-repository-package` 的使用者有東西可釘，這已經解決眼前的問題。
- **bench 進 CI 並比較基線**：runner 的效能噪音使數字不可比，會製造假警報。bench 維持本機執行（0010 §9.2 的作法）。
