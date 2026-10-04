# Ubuntu 26.04 2台SSD 待機系運用 手順書（LVM + スナップショット同期）

## 0. 概要

### 0-1. 構成と運用

- PC の SSD スロットは1つだけで、**スロットに入れるのは常に1台**。
- サブ SSD は、**バックアップのときだけ USB 外付けケースで接続**する。
- 各 SSD は、それぞれ独立に Ubuntu をインストールしておく。

```
[スロット] SSD-A（メイン）              [USBケース] SSD-B（サブ）※バックアップ時のみ接続
├─ p1  ESP    /boot/efi  vfat           ├─ p1  ESP
├─ p2  /boot             ext4           ├─ p2  /boot
└─ p3  PV ── VG vg_ssd_a                └─ p3  PV ── VG vg_ssd_b
             ├─ LV root  ext4 /                      ├─ LV root
             └─ VFree（スナップショット用）             └─ VFree
```

バックアップの流れ（`sudo ssd-sync vg_ssd_b`）:

```
A: LV root ─スナップショット(ro)─rsync─▶ B: LV root
A: /boot   ─────────────────rsync─▶ B: /boot  （grub.cfg は除外）
B に chroot: grub-install → update-initramfs → update-grub   ※B の UUID と VG 名で再生成
```

### 0-2. LVM 用語

| 用語 | 意味 | 確認コマンド |
|---|---|---|
| PV | LVM に割り当てたパーティション（p3） | `sudo pvs` |
| VG | PV を束ねた容量プール | `sudo vgs` |
| LV | VG から切り出した仮想パーティション。ここに ext4 を作る | `sudo lvs` |
| VFree | VG のうち、どの LV にも割り当てていない容量。スナップショットはここから確保される | `sudo vgs` |

### 0-3. ルール

1. **VG 名はディスクごとに変える**（`vg_ssd_a`, `vg_ssd_b`, 交換後は `vg_ssd_c` …）。バックアップ時は2台が同時に見えるので、名前が同じだと衝突する。
2. **`dd` でクローンしない。** UUID が重複するため。
3. **fstab・ESP・grub.cfg は同期しない**（ディスク固有の情報を含むため）。`/etc/fstab` を変更したときは両方に手で反映する。
4. サブは「待機系」であり、バックアップではない。誤って削除したものも同期で伝搬するので、重要なデータは restic / borg などで別の媒体に世代管理つきで保存する。

---

## 1. メインSSD（SSD-A）の初期設定

### 1-1. 現状確認

VM で試す場合は、先に VM のスナップショットを取っておきます。

```bash
sudo vgs; sudo lvs
cat /etc/fstab
```

fstab の `/` の行が `/dev/disk/by-id/dm-uuid-LVM-...` の形式なら、名前を変えても fstab の修正は不要です（UUID で指定しているため）。`/dev/mapper/ubuntu--vg-ubuntu--lv` の形式の場合は、1-2 の後で書き換えてください。

### 1-2. VG 名・LV 名の変更

```bash
sudo vgrename ubuntu-vg vg_ssd_a
sudo lvrename vg_ssd_a ubuntu-lv root
ls -l /dev/mapper/                 # vg_ssd_a-root があること
sudo update-initramfs -u -k all
```

> この時点では `sudo update-grub` は失敗します（`failed to get canonical path of /dev/mapper/ubuntu--vg-ubuntu--lv`）。`/` のマウント情報に旧名が再起動まで残るためです。grub.cfg は旧名のままなので、次の再起動では手で新しい名前を指定します。

### 1-3. GRUB で新しい名前を指定して起動し、grub.cfg を再生成する

1. `sudo reboot` を実行し、起動直後に `Esc` を押して GRUB メニューを出します（押しすぎると `grub>` プロンプトに落ちるので数回だけ）。
2. 先頭のエントリで `e` を押し、`linux` 行の `root=/dev/mapper/ubuntu--vg-ubuntu--lv` を `root=/dev/mapper/vg_ssd_a-root` に書き換えて `Ctrl-X` で起動します。
3. 起動したら grub.cfg を再生成します。

```bash
findmnt -no SOURCE /                    # /dev/mapper/vg_ssd_a-root
sudo update-grub
grep -m2 'root=' /boot/grub/grub.cfg    # root=/dev/mapper/vg_ssd_a-root
sudo reboot                             # 手を加えずに起動できることを確認
```

`(initramfs)` のプロンプトで止まった場合は、`lvm vgchange -ay` → `exit` で起動し、1-3 をやり直します。

### 1-4. スナップショット用の VFree を確保する

```bash
sudo vgs vg_ssd_a        # VFree を確認
```

- **目安**: バックアップ中にメインへ書き込まれる量より大きいこと。10〜20G あれば通常は足ります（スクリプトの既定値は 10G）。
- VFree が 0 の場合は、次の手順で root LV を縮小します。VM ならディスクを拡張して `growpart /dev/vda 3` → `pvresize /dev/vda3` でも作れます。

**(1) 通常起動の状態で、縮小後のサイズを決める**

```bash
df -h /                                   # 使用量
sudo lvs -o lv_name,lv_size vg_ssd_a      # 現在の LV サイズ
```

縮小後のサイズは「使用量＋十分な余裕」にします。A と B で同じ値にするので、メモしておきます。重要なデータは事前に別の媒体へ退避しておいてください。

**(2) Live USB（Try Ubuntu）で縮小する**

```bash
sudo -i
vgscan
vgchange -ay vg_ssd_a
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS      # vg_ssd_a-root がマウントされていないこと

e2fsck -f /dev/vg_ssd_a/root               # 縮小の前に必ず検査する
lvreduce -r -L 20G vg_ssd_a/root           # 縮小後の「絶対サイズ」を指定（20G は例）
e2fsck -f /dev/vg_ssd_a/root               # エラーがないこと
vgs vg_ssd_a                               # VFree が増えていること
vgchange -an vg_ssd_a
poweroff
```

- **`-r` は必須です。** ext4 → LV の順で縮小されます。付けずに実行すると、ファイルシステムが壊れます。
- 途中で中断したり、電源を切ったりしないでください。

**(3) SSD から起動して確認する**

1. Live USB を抜いて電源を入れ、SSD から通常どおり起動します。
2. 起動したディスクと LV のサイズを確認します。
   ```bash
   findmnt -no SOURCE /                        # /dev/mapper/vg_ssd_a-root
   df -h /                                     # Size が縮小後のサイズになっていること
   sudo lvs -o lv_name,lv_size vg_ssd_a        # root が縮小後のサイズ
   sudo vgs -o vg_name,vg_size,vg_free vg_ssd_a # VFree が増えていること
   ```
3. スナップショットを実際に作成・削除できるか試します。
   ```bash
   sudo lvcreate -s -L 10G -n root_snap vg_ssd_a/root
   sudo lvs vg_ssd_a                           # root_snap が表示され、Data% が小さい値
   sudo lvremove -y vg_ssd_a/root_snap
   sudo vgs vg_ssd_a                           # VFree が元の値に戻っていること
   ```

UUID は変わらないので、fstab や GRUB の修正は不要です。

---

## 2. サブSSD（SSD-B）の初期設定

1. スロットから SSD-A を外し、SSD-B を入れます。
2. Ubuntu 26.04 をインストールします。
   - 「LVM を使う」を選び、ユーザー名は A と同じにします。
   - 「カスタムストレージレイアウト」で root LV を A と同じサイズにしておけば、1-4 の縮小作業は不要です。
3. SSD-B から起動し、1-1〜1-4 を **`vg_ssd_b`** に読み替えて実施します。
   ```bash
   sudo vgrename ubuntu-vg vg_ssd_b
   sudo lvrename vg_ssd_b ubuntu-lv root
   sudo update-initramfs -u -k all
   # → GRUB で root=/dev/mapper/vg_ssd_b-root を指定して起動 → sudo update-grub
   ```
4. root LV のサイズを A と同じにそろえます（SSD-B で起動した状態で）。
   ```bash
   sudo lvs -o lv_name,lv_size --units g vg_ssd_b     # 例: root 15.00g
   sudo vgs -o vg_name,vg_free --units g vg_ssd_b      # VFree
   ```
   - B の root が A より**小さい**場合は、拡張します（オンラインでできます）。
     ```bash
     sudo lvextend -r -L 20G vg_ssd_b/root     # 20G = A の root サイズ（絶対指定）
     ```
   - B の root が A より**大きく**、VFree が足りない場合は、1-4 の手順で Live USB から縮小します。
   - 最後に、A と B で root のサイズと VFree がそろっていることを確認します。
5. 電源を切り、SSD-A をスロットに戻します。SSD-B は USB ケースに入れます。
6. 初回の接続確認をします。SSD-A で起動したあとに、SSD-B を USB で接続します。
   ```bash
   findmnt -no SOURCE /                     # vg_ssd_a-root で起動していること
   sudo pvs                                 # /dev/nvme0n1p3 vg_ssd_a と /dev/sdX3 vg_ssd_b
   sudo vgs                                 # 2つの VG が別名で見えること
   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS    # sdX の各パーティションがマウントされていないこと
   ```
   問題がなければ、3（スクリプトの配置）と 4（初回バックアップ）に進みます。初回のバックアップ後は、必ず 4-3 の起動確認をしてください。

---

## 3. バックアップ用の準備（メインで1回だけ）

```bash
# スクリプトを配置する
sudo install -m 0755 ssd-sync.sh /usr/local/sbin/ssd-sync

# （推奨）USB を接続したときの自動マウントを無効にする（デスクトップのユーザーで実行）
gsettings set org.gnome.desktop.media-handling automount false
```

自動マウントが有効なままだと、USB を接続した時点でサブの /boot や ESP が `/media/...` にマウントされます。この場合スクリプトは安全のため中止し、`udisksctl unmount -b <デバイス>` の実行を促します。

### 3-1. メインの登録とサブ起動時の警告壁紙

どちらがメインかを `/etc/ssd-sync/main-vg` に書いておきます。このファイルは同期でサブにもコピーされるので、サブで起動すると「自分の VG ≠ メイン」と判定されます。

- **ログイン時の動作**：サブで起動していれば、警告用の壁紙（赤いストライプ、VG 名、最終同期日時）に切り替わり、通知も表示されます。メインで起動していれば何もしません。
- **`ssd-sync` の動作**：サブから起動した状態で誤って同期すると、古いサブの内容でメインを上書きしてしまいます。これを防ぐため、`-f` を付けない限り中止します。

```bash
# メインの VG を登録する
sudo mkdir -p /etc/ssd-sync
echo vg_ssd_a | sudo tee /etc/ssd-sync/main-vg

# 壁紙切り替えスクリプトとログイン時の自動起動を配置する
sudo install -m 0755 ssd-role-indicator /usr/local/bin/ssd-role-indicator
sudo install -m 0644 ssd-role-indicator.desktop /etc/xdg/autostart/ssd-role-indicator.desktop

# 動作確認（メインで起動した状態のまま）
ssd-role-indicator --as sub     # 警告壁紙に変わる
ssd-role-indicator --as main    # 元の壁紙に戻る
```

これらのファイルは root ファイルシステム上にあるので、次の同期でサブにも配置されます。サブ側で個別に作業する必要はありません。

- 壁紙の設定はユーザーの dconf に保存され、これもメインから同期されます。そのため、サブで警告壁紙に変わっても、次の同期でメインの設定に上書きされます。
- 警告壁紙は `~/.local/state/ssd-role-indicator/` に生成されます。

---

## 4. バックアップ（毎回）

### 4-1. 事前チェック

- [ ] `apt` や `unattended-upgrades` が動いていないこと（スクリプトでもチェックします）
- [ ] 大量の書き込みを伴う作業はしばらく控える。DB・VM・コンテナは必要に応じて停止する
- [ ] `sudo vgs` で、メイン側の VFree がスナップショットサイズ以上あること

### 4-2. 実行

```bash
# 1) サブを USB ケースで接続し、認識されたことを確認する
sudo vgs                                  # vg_ssd_a と vg_ssd_b が表示される
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS     # サブのパーティションがマウントされていないこと

# 2) ドライラン（差分の確認のみ）→ 本番
sudo ssd-sync -n vg_ssd_b
sudo ssd-sync vg_ssd_b                    # 書き込みが多いときは -s 20G

# 3) 取り外す（スクリプトの終了時に VG は非活性化済み）
udisksctl power-off -b /dev/sdX           # sdX はサブのディスク（lsblk で確認）
```

- 最後に「===== 完了 =====」と表示されれば成功です。ログは `/var/log/ssd-sync.log` に残ります。
- 失敗した場合も、スナップショットの削除とアンマウントは自動で行われます。
- 同期元は、今起動している VG から自動で判定されます。役割が入れ替わった後も、同期先の VG 名を指定するだけで使えます。

### 4-3. 起動確認（初回と、カーネル更新後の同期のあと）

サブから実際に起動できるかを確認します。次のどちらかの方法で行います。

- **USB ケースのまま起動する**：ファームウェアのブートメニュー（F12 など）から USB ディスクを選びます。root を LV 名で指定しているので、USB 接続でも起動できます。ファームウェアで USB 起動が有効になっている必要があります。
- **スロットに差し替えて起動する**。

起動したら確認します。

```bash
findmnt -no SOURCE /                 # /dev/mapper/vg_ssd_b-root
cat /var/lib/ssd-sync/last-sync      # 最終同期日時
```

---

## 5. 定期点検

| 頻度 | 内容 |
|---|---|
| 同期のたび | 「完了」と表示されたことを確認 |
| 月1回程度 | サブから起動確認（4-3）。ディスクの健康状態の確認（`sudo smartctl -a /dev/nvme0n1`：Percentage Used、Media Errors、Available Spare） |
| 定期 | `/home` などを restic / borg で別の媒体へ世代バックアップ |

---

## 6. 故障時の手順

### 6-1. メインSSD（A）が故障した場合

1. 電源を切り、SSD-A を外して、**SSD-B をスロットに入れます**。
2. 起動します。UEFI の起動エントリは A を指したままですが、各 ESP にあるフォールバック用のブートローダ（`\EFI\BOOT\BOOTX64.EFI`）で通常は自動的に起動します。起動しない場合は、ファームウェアのブートメニューで SSD を選んでください。
3. 確認します。
   ```bash
   findmnt -no SOURCE /                 # vg_ssd_b-root
   cat /var/lib/ssd-sync/last-sync      # どの時点の状態か
   ```
4. **B をメインとして登録します。** 登録するまでは、警告壁紙が表示され続け、`ssd-sync` も実行できません。
   ```bash
   echo vg_ssd_b | sudo tee /etc/ssd-sync/main-vg
   ssd-role-indicator              # 元の壁紙に戻る（次回ログイン時にも自動で戻る）
   ```
5. 以後は B がメインです。

### 6-2. 新しい SSD（C）をサブとして組み込む

1. 電源を切り、SSD-B を外して、**新しい SSD をスロットに入れます**。インストーラが B に触れないようにするためです。
2. 2 と同じ手順でインストールし、VG 名を **`vg_ssd_c`** にします（名前は再利用しない）。root LV のサイズと VFree は B と同じにします。
3. SSD-B をスロットに戻し、SSD-C は USB ケースに入れます。
4. B から起動します。起動しない場合は、ファームウェアのブートメニューで SSD を選んでください。
5. `sudo ssd-sync -n vg_ssd_c` → `sudo ssd-sync vg_ssd_c` を実行し、4-3 で C から起動できるか確認します。

### 6-3. サブSSDが故障した場合

6-2 と同じ手順で、新しい SSD を組み込みます。

### 6-4. メインは壊れていないが、アップデート失敗などで起動しない場合

- **起動できない状態のメインからは同期しないでください。** 壊れた状態がサブに伝搬します。
- サブから（USB ケースのまま、または差し替えて）起動し、調査します。
- サブの状態でメインを書き戻す場合は、サブから起動した状態でメインを接続し、逆方向に同期します。この場合、A の root は B の状態で上書きされます。A に残っている必要なデータは、先に退避してください。
  逆方向の同期では `-f` が必要です（`main-vg` は vg_ssd_a のままでかまいません）。
  ```bash
  sudo ssd-sync -n -f vg_ssd_a
  sudo ssd-sync -f vg_ssd_a
  ```

---

## 7. トラブルシューティング

| 症状 | 対処 |
|---|---|
| `update-grub` で `failed to get canonical path` | VG 名を変えた直後に起きる。1-3 の手順で起動してから実行する |
| `(initramfs)` で止まる | `lvm vgchange -ay` → `exit` で起動し、`update-grub` を実行する |
| `grub>` / `grub rescue>` で止まる | もう一方の SSD から起動し、壊れた側を接続して `sudo ssd-sync <その VG>` を実行する（ESP と grub.cfg が再生成される） |
| 「マウント中です」で中止 | 自動マウントによるもの。表示された `udisksctl unmount -b ...` を実行して再実行する |
| 「スナップショットが無効化されました」 | `-s 20G` などで再実行するか、書き込みの少ないときに実行する |
| 「vg_ssd_b を非活性化できませんでした」 | 同期先が別のマウント名前空間でマウントされたまま残っている（旧版スクリプトで発生）。USB を外す前に再起動する |
| 「現在はサブで起動しています」で中止 | 意図した逆方向の同期なら `-f` を付ける。メインを切り替えた場合は `/etc/ssd-sync/main-vg` を更新する（6-1） |
| 「前回のスナップショットが残っています」 | `sudo lvremove vg_ssd_a/root_snap` |
| 同名の VG が2つ見える | 名前の変更漏れ。`sudo vgs -o +vg_uuid` で確認し、`sudo vgrename <UUID> <新しい名前>` |
| USB 接続したサブの VG が見えない | `/etc/lvm/devices/system.devices` が存在する場合は、`sudo lvmdevices --adddev /dev/sdX3` |
