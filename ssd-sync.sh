#!/usr/bin/env bash
# =============================================================================
# @file    ssd-sync.sh
# @brief   稼働中のメインSSDから待機系(サブ)SSDへ、起動可能な状態を保ったまま同期する
#
# @details
#   前提構成:
#     2台のSSDそれぞれに独立して Ubuntu を LVM 構成でインストールし、
#     VG 名をディスクごとに変えてあること (例: vg_ssd_a / vg_ssd_b)。
#     root LV 名は両ディスクとも "root"。
#
#   処理の流れ:
#     1. 現在 "/" をマウントしている LV をソースとして自動判定する
#        (メイン/サブの役割が入れ替わってもスクリプトの修正は不要)
#     2. 同期先 VG を活性化し、同期先の fstab がそれ自身を指しているか検証する
#        (誤ったディスクへの上書きを防止)
#     3. ソースの root LV に LVM スナップショットを作成する。
#        lvcreate -s は origin を dm suspend する際に fsfreeze を行うため、
#        ある時点で固定された、クラッシュ一貫性のある状態が得られる
#     4. スナップショットを read-only でマウントし、同期先 root LV へ rsync する
#     5. スナップショットをすぐ削除する (COW による書き込み性能低下を最小化)
#     6. /boot (LVM 外の ext4) を稼働中の状態から直接 rsync する
#        (/boot はカーネル更新時しか変化しないため、apt 非実行中なら安全)
#     7. 同期先へ chroot し、ESP 上の shim/GRUB、initramfs、grub.cfg を
#        「同期先自身の UUID / VG 名」で再生成する
#     8. 後片付け (アンマウント、同期先 VG の非活性化)
#
#   ディスク固有の情報 (fstab、crypttab、LVM メタデータのバックアップ、
#   ESP、grub.cfg 等) は同期しない。同期先の /boot と ESP の位置は、
#   同期先自身の /etc/fstab から求める。
#
# @usage   sudo ssd-sync.sh [-n] [-f] [-s SIZE] <dest_vg>
#            -n       ドライラン (rsync -n で差分表示のみ。ブートローダは更新しない)
#            -f       同期元がメイン (/etc/ssd-sync/main-vg) でなくても実行する (逆方向同期用)
#            -s SIZE  スナップショットサイズ (LVM 表記。既定: 10G)
#            dest_vg  同期先 (サブ) の VG 名 (例: vg_ssd_b)
#
# @retval  0    成功
# @retval  1    失敗 (詳細は標準出力および /var/log/ssd-sync.log)
# @retval  130  中断 (Ctrl-C / SIGTERM)
# =============================================================================

set -euo pipefail

# ロック用 fd 9 が LVM コマンドに継承されると "File descriptor 9 ... leaked" の
# 警告が出る (動作に影響はない)。bash では fd に O_CLOEXEC を付けられないため警告を抑止する
export LVM_SUPPRESS_FD_WARNINGS=1

# -----------------------------------------------------------------------------
# 設定値
# -----------------------------------------------------------------------------
readonly lv_name="root"                     # 両ディスク共通の root LV 名
readonly snap_name="${lv_name}_snap"        # 一時スナップショット LV 名
readonly work_dir="/mnt/ssd-sync"           # 作業用マウントポイントの親
                                            # (/run 配下にすると chroot 用に /run を
                                            #  rbind した際に自分自身を含む入れ子になるため避ける)
readonly snap_mnt="${work_dir}/snap"        # スナップショットのマウント先
readonly sub_mnt="${work_dir}/sub"          # 同期先 root のマウント先 (chroot 先)
readonly log_file="/var/log/ssd-sync.log"
readonly lock_file="/run/ssd-sync.lock"
readonly stamp_rel="var/lib/ssd-sync"       # 同期先に同期記録を残すディレクトリ
readonly main_vg_file="/etc/ssd-sync/main-vg" # 現在のメイン VG 名 (壁紙切替と共用。同期される)

# root LV の同期除外リスト (rsync パターン。先頭 "/" は転送ルート基準)
# 除外されたパスは --delete の対象にもならないため、同期先の固有ファイルが保護される
readonly -a root_excludes=(
    "/etc/fstab"                            # ディスク固有 UUID を含む
    "/etc/crypttab"                         # 同上 (LUKS 使用時)
    "/etc/initramfs-tools/conf.d/resume"    # ハイバネート先 swap の UUID
    "/etc/lvm/backup/"                      # VG メタデータのバックアップ (VG 固有)
    "/etc/lvm/archive/"                     # 同上 (履歴)
    "/etc/lvm/devices/"                     # LVM devices file (使用時。PV 固有)
    "/boot/*"                               # /boot は別 FS。sync_boot() で別途同期
    "/swap.img"                             # swap ファイルは各ディスクで持つ
    "/tmp/*"
    "/var/tmp/*"
    "/lost+found"
    "/${stamp_rel}/"                        # 同期先の同期記録を保護
    "${work_dir}/*"                         # 作業用マウントポイント
)

# /boot の同期除外リスト (転送ルートは /boot)
readonly -a boot_excludes=(
    "/efi/"                                 # ESP はディスク固有。grub-install で更新
    "/grub/grub.cfg"                        # update-grub で同期先用に再生成
    "/grub/grubenv"                         # 起動失敗フラグ等のディスク固有状態
    "/lost+found"
)

# -----------------------------------------------------------------------------
# 実行時状態 (cleanup で参照するためグローバル)
# -----------------------------------------------------------------------------
snap_size="10G"         # スナップショット (COW 領域) サイズ
dry_run=0               # 1: ドライラン
force_reverse=0         # 1: メイン以外からの同期 (逆方向同期) を許可
dest_vg=""              # 同期先 VG
src_vg=""               # 同期元 VG (自動判定)
sub_boot_dev=""         # 同期先 /boot のデバイス
sub_esp_dev=""          # 同期先 ESP のデバイス
snap_created=0          # 1: スナップショット作成済み (要削除)
dest_activated=0        # 1: 同期先 VG を活性化済み (要非活性化)
rsync_base=()           # rsync 共通オプション

##
# @brief  時刻付きでログを出力する
# @param  $* メッセージ
##
log() {
    printf '[%(%F %T)T] %s\n' -1 "$*"
}

##
# @brief  エラーメッセージを出力して終了する (後片付けは EXIT トラップで行う)
# @param  $* メッセージ
##
die() {
    log "ERROR: $*"
    exit 1
}

##
# @brief  使い方を表示する
##
usage() {
    cat <<EOF
Usage: sudo ${0##*/} [-n] [-f] [-s SIZE] <dest_vg>
  -n       dry run (show differences only, bootloader is not updated)
  -f       allow syncing from a non-main VG (reverse sync)
  -s SIZE  snapshot size in LVM notation (default: ${snap_size})
  dest_vg  destination (standby) VG name, e.g. vg_ssd_b
EOF
}

##
# @brief  EXIT トラップ。途中で失敗しても必ずマウントとスナップショットを片付ける
# @details
#   スナップショットを残すと origin への書き込みが COW で遅くなり続け、
#   COW 領域が満杯になった時点で無効化されるため、必ず削除する。
##
cleanup() {
    local rc=$?
    set +e
    if mountpoint -q "${sub_mnt}"; then
        sync
        # chroot 用 rbind (rslave 済み) を含めて再帰的にアンマウント
        umount -R "${sub_mnt}" || umount -R -l "${sub_mnt}"
    fi
    if mountpoint -q "${snap_mnt}"; then
        umount "${snap_mnt}" || umount -l "${snap_mnt}"
    fi
    if (( snap_created )); then
        lvremove -y "${src_vg}/${snap_name}" >/dev/null && snap_created=0
    fi
    if (( dest_activated )); then
        # 同期先 LV を非活性化し、誤マウント・誤書き込みを防ぐ
        if ! vgchange -an "${dest_vg}" >/dev/null; then
            log "WARNING: ${dest_vg} を非活性化できませんでした。USB を外す前に再起動してください"
            (( rc == 0 )) && rc=1
        fi
    fi
    if (( rc == 0 )); then
        log "===== 完了 ====="
    else
        log "===== 異常終了 (rc=${rc}) ====="
    fi
    exit "${rc}"
}

##
# @brief  fstab からマウントポイントに対応するデバイス指定 (第1フィールド) を取り出す
# @param  $1 fstab のパス
# @param  $2 マウントポイント
# @return 標準出力にデバイス指定 (見つからなければ空)
##
fstab_spec() {
    local fstab="$1" mnt_point="$2"
    awk -v m="${mnt_point}" '$1 !~ /^#/ && NF >= 2 && $2 == m { print $1; exit }' "${fstab}"
}

##
# @brief  fstab のデバイス指定 (UUID= / PARTUUID= / LABEL= / パス) を実デバイスへ解決する
# @param  $1 デバイス指定
# @return 標準出力に正規化したデバイスパス (/dev/dm-N 等)。解決できなければ 1 を返す
##
resolve_spec() {
    local spec="$1"
    local dev
    case "${spec}" in
        UUID=*)     dev="/dev/disk/by-uuid/${spec#UUID=}" ;;
        PARTUUID=*) dev="/dev/disk/by-partuuid/${spec#PARTUUID=}" ;;
        LABEL=*)    dev="/dev/disk/by-label/${spec#LABEL=}" ;;
        *)          dev="${spec}" ;;
    esac
    [[ -n "${dev}" && -b "${dev}" ]] || return 1
    readlink -f "${dev}"
}

##
# @brief  実行前提 (権限・コマンド・apt 非実行中) を確認する
##
check_prerequisites() {
    local cmd
    [[ ${EUID} -eq 0 ]] || die "root 権限で実行してください"
    for cmd in lvs lvcreate lvremove vgs vgchange dmsetup rsync chroot findmnt \
               lsblk mountpoint numfmt fuser blkid flock; do
        command -v "${cmd}" >/dev/null || die "コマンドが見つかりません: ${cmd}"
    done
    # apt/dpkg 実行中は /boot や /usr が更新途中の状態になり得るため中止する
    if fuser -s /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null; then
        die "apt/dpkg が実行中です。完了後に再実行してください"
    fi
}

##
# @brief  現在の "/" が載っている VG/LV を同期元として判定する
##
detect_source() {
    local root_dev src_lv
    root_dev="$(findmnt -no SOURCE /)"
    read -r src_vg src_lv < <(lvs --noheadings -o vg_name,lv_name "${root_dev}" 2>/dev/null) \
        || die "/ (${root_dev}) が LVM 上にありません"
    [[ "${src_lv}" == "${lv_name}" ]] \
        || die "同期元 root LV 名が '${lv_name}' ではありません: ${src_vg}/${src_lv}"
    log "同期元: ${src_vg}/${src_lv} (${root_dev})"
}

##
# @brief  同期元が「メイン」であることを確認する
# @details
#   /etc/ssd-sync/main-vg に記載された VG 以外 (= サブ) から起動した状態で同期すると、
#   古いサブの内容でメインを上書きしてしまう。これを防ぐため、-f 指定時以外は中止する。
#   ファイルが無ければ確認しない。
##
check_role() {
    local main_vg
    [[ -r "${main_vg_file}" ]] || return 0
    main_vg="$(tr -d '[:space:]' < "${main_vg_file}")"
    [[ -n "${main_vg}" && "${src_vg}" != "${main_vg}" ]] || return 0
    if (( force_reverse )); then
        log "WARNING: メイン (${main_vg}) 以外の ${src_vg} から同期します (-f 指定)"
    else
        die "現在はサブ (${src_vg}) で起動しています (メインは ${main_vg})。" \
            "逆方向に同期する場合は -f を付けてください"
    fi
}

##
# @brief  VG/LV の存在、残存スナップショット、スナップショット用空き容量を確認する
##
check_volumes() {
    local vfree need
    [[ "${dest_vg}" != "${src_vg}" ]] || die "同期先が稼働中の VG (${src_vg}) です"
    vgs "${dest_vg}" >/dev/null 2>&1 || die "VG が見つかりません: ${dest_vg}"
    lvs "${dest_vg}/${lv_name}" >/dev/null 2>&1 \
        || die "LV が見つかりません: ${dest_vg}/${lv_name}"
    if lvs "${src_vg}/${snap_name}" >/dev/null 2>&1; then
        die "前回のスナップショットが残っています: sudo lvremove ${src_vg}/${snap_name}"
    fi
    # スナップショットの COW 領域は VG の空き (VFree) から確保される
    vfree="$(vgs --noheadings --units b --nosuffix -o vg_free "${src_vg}" | tr -d ' ')"
    need="$(numfmt --from=iec "${snap_size}")"
    (( vfree >= need )) \
        || die "${src_vg} の空き不足: VFree=$(numfmt --to=iec "${vfree}") < ${snap_size}"
}

##
# @brief  同期先 VG を活性化し、同期先 root LV が未マウントであることを確認する
##
activate_dest() {
    local mnts
    vgchange -ay "${dest_vg}" >/dev/null
    dest_activated=1
    mnts="$(lsblk -no MOUNTPOINTS "/dev/${dest_vg}/${lv_name}" | tr -d '[:space:]')"
    [[ -z "${mnts}" ]] \
        || die "同期先 ${dest_vg}/${lv_name} がマウント中です (${mnts})。" \
               "自動マウントの場合は: udisksctl unmount -b /dev/${dest_vg}/${lv_name}"
}

##
# @brief  指定デバイスが (デスクトップの自動マウント等で) マウントされていないことを確認する
# @param  $1 デバイスパス
# @param  $2 表示用の名前
##
ensure_unmounted() {
    local dev="$1" name="$2" mnts
    mnts="$(lsblk -no MOUNTPOINTS "${dev}" | tr -d '[:space:]')"
    [[ -z "${mnts}" ]] \
        || die "同期先の ${name} (${dev}) がマウント中です (${mnts})。" \
               "自動マウントの場合は: udisksctl unmount -b ${dev}"
}

##
# @brief  同期先 root をマウントし、同期先が「同期先自身の fstab」を持つか検証する
# @details
#   同期先 fstab の "/" 行が同期先 LV 自身を指していることを確認する。
#   これで「別ディスクを誤指定した」「過去に fstab を上書きしてしまった」等を検出する。
#   併せて同期先の /boot, /boot/efi のデバイスを求め、稼働中のものと異なることを確認する。
##
mount_dest_root() {
    local fstab spec dest_dev
    mount "/dev/${dest_vg}/${lv_name}" "${sub_mnt}"
    fstab="${sub_mnt}/etc/fstab"
    [[ -f "${fstab}" ]] || die "同期先に /etc/fstab がありません (Ubuntu 未インストール?)"

    dest_dev="$(readlink -f "/dev/${dest_vg}/${lv_name}")"
    spec="$(fstab_spec "${fstab}" /)"
    [[ "$(resolve_spec "${spec}" || true)" == "${dest_dev}" ]] \
        || die "同期先 fstab の / (${spec}) が ${dest_vg}/${lv_name} を指していません"

    spec="$(fstab_spec "${fstab}" /boot)"
    sub_boot_dev="$(resolve_spec "${spec}")" || die "同期先の /boot を解決できません: ${spec}"
    spec="$(fstab_spec "${fstab}" /boot/efi)"
    sub_esp_dev="$(resolve_spec "${spec}")" || die "同期先の /boot/efi を解決できません: ${spec}"

    [[ "${sub_boot_dev}" != "$(readlink -f "$(findmnt -no SOURCE /boot)")" ]] \
        || die "同期先の /boot が稼働中の /boot と同一です"
    [[ "${sub_esp_dev}" != "$(readlink -f "$(findmnt -no SOURCE /boot/efi)")" ]] \
        || die "同期先の ESP が稼働中の ESP と同一です"
    # USB 接続時は GNOME 等が /boot, ESP を /media 配下へ自動マウントすることがある
    ensure_unmounted "${sub_boot_dev}" "/boot"
    ensure_unmounted "${sub_esp_dev}" "ESP"
    log "同期先: root=${dest_dev} boot=${sub_boot_dev} esp=${sub_esp_dev}"
}

##
# @brief  同期元 root LV のスナップショットを作成し read-only でマウントする
# @note   ext4 は同一 UUID の FS を同時にマウントできる (XFS は nouuid が必要)
##
create_snapshot() {
    log "スナップショット作成: ${src_vg}/${snap_name} (${snap_size})"
    lvcreate -q -s -L "${snap_size}" -n "${snap_name}" "${src_vg}/${lv_name}" >/dev/null
    snap_created=1
    mount -o ro "/dev/${src_vg}/${snap_name}" "${snap_mnt}"
}

##
# @brief  スナップショットが有効なまま同期を終えられたか確認する
# @details
#   COW 領域 (-s SIZE) が満杯になると lv_attr の5文字目が 'I' (invalid) になり、
#   以降の読み出しは I/O エラーになる。rsync も失敗するはずだが念のため確認する。
##
check_snapshot() {
    local attr usage
    read -r attr usage < <(lvs --noheadings -o lv_attr,data_percent "${src_vg}/${snap_name}")
    log "スナップショット使用率: ${usage}%"
    [[ "${attr:4:1}" != "I" ]] \
        || die "スナップショットが無効化されました。-s でサイズを増やして再実行してください"
}

##
# @brief  スナップショットをアンマウントして削除する
##
remove_snapshot() {
    umount "${snap_mnt}"
    lvremove -y "${src_vg}/${snap_name}" >/dev/null
    snap_created=0
    log "スナップショット削除"
}

##
# @brief  スナップショットから同期先 root LV へ同期する
##
sync_root() {
    local -a opts=("${rsync_base[@]}")
    local pat
    for pat in "${root_excludes[@]}"; do
        opts+=("--exclude=${pat}")
    done
    log "root 同期開始: ${snap_mnt}/ -> ${sub_mnt}/"
    rsync "${opts[@]}" "${snap_mnt}/" "${sub_mnt}/"
}

##
# @brief  稼働中の /boot を同期先 /boot へ同期し、同期先 ESP もマウントする
# @note   同期先 /boot は root 同期の「後」にマウントする。
#         先にマウントすると root 同期の --delete が /boot の中身に及ぶ危険があるため
#         (二重の安全策として root_excludes にも "/boot/*" を入れている)。
##
sync_boot() {
    local -a opts=("${rsync_base[@]}")
    local pat
    for pat in "${boot_excludes[@]}"; do
        opts+=("--exclude=${pat}")
    done
    mount "${sub_boot_dev}" "${sub_mnt}/boot"
    log "/boot 同期開始"
    rsync "${opts[@]}" /boot/ "${sub_mnt}/boot/"
    mount "${sub_esp_dev}" "${sub_mnt}/boot/efi"
}

##
# @brief  同期先へ chroot し、ブートに必要なものを同期先自身の構成で再生成する
# @details
#   - grub-install     : ESP 上の shim/grubx64.efi を /boot 側 GRUB と同じ版に揃え、
#                        ESP の grub.cfg (スタブ) を同期先 /boot の UUID で書き直す。
#                        --no-nvram で UEFI ブートエントリ (NVRAM) は変更しない。
#                        Secure Boot 用の署名済み GRUB は \EFI\ubuntu を前提とするため
#                        bootloader-id は "ubuntu" のままにする。
#   - update-initramfs : 同期先自身の fstab/crypttab を基に initramfs を再生成
#   - update-grub      : root=/dev/mapper/<同期先VG>-root で grub.cfg を再生成
#   /dev, /proc, /sys, /run は rbind し、rslave にしてアンマウントがホストへ
#   伝播しないようにする (systemd 環境ではマウントが shared のため必須)。
##
update_bootloader() {
    local d boot_uuid root_uuid dest_dm
    for d in dev proc sys run; do
        mount --rbind "/${d}" "${sub_mnt}/${d}"
        mount --make-rslave "${sub_mnt}/${d}"
    done

    log "ブートローダ・initramfs 再生成 (chroot)"
    chroot "${sub_mnt}" /usr/bin/env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 HOME=/root \
        /bin/bash -euc '
            grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                         --bootloader-id=ubuntu --no-nvram
            update-initramfs -u -k all
            update-grub
        ' 9>&-      # ロック用 fd を chroot 側へ渡さない (env -i で抑止用の環境変数も消えるため)

    # --- 生成結果の検証 ---
    # ESP のスタブ grub.cfg が同期先 /boot の UUID を探しにいくこと
    boot_uuid="$(blkid -s UUID -o value "${sub_boot_dev}")"
    grep -qF "${boot_uuid}" "${sub_mnt}/boot/efi/EFI/ubuntu/grub.cfg" \
        || die "ESP の grub.cfg が同期先 /boot (${boot_uuid}) を指していません"

    # grub.cfg のカーネル引数 root= が同期先 root LV を指すこと
    dest_dm="/dev/mapper/$(dmsetup info -c --noheadings -o name "/dev/${dest_vg}/${lv_name}")"
    root_uuid="$(blkid -s UUID -o value "/dev/${dest_vg}/${lv_name}")"
    grep -qF -e "root=${dest_dm} " -e "root=UUID=${root_uuid} " "${sub_mnt}/boot/grub/grub.cfg" \
        || die "grub.cfg の root= が同期先 (${dest_dm}) になっていません"
    log "検証OK: ESP -> /boot(${boot_uuid}), root=${dest_dm}"
}

##
# @brief  同期先に同期記録を残す (同期先から起動したときに鮮度を確認できる)
##
write_stamp() {
    mkdir -p "${sub_mnt}/${stamp_rel}"
    {
        printf 'synced_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'source_vg=%s\n' "${src_vg}"
        printf 'dest_vg=%s\n'   "${dest_vg}"
        printf 'kernel=%s\n'    "$(uname -r)"
    } > "${sub_mnt}/${stamp_rel}/last-sync"
}

##
# @brief  エントリポイント
# @param  $@ コマンドライン引数
##
main() {
    local opt
    local -a orig_args=("$@")
    while getopts ":nfs:h" opt; do
        case "${opt}" in
            n) dry_run=1 ;;
            f) force_reverse=1 ;;
            s) snap_size="${OPTARG}" ;;
            h) usage; exit 0 ;;
            *) usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [[ $# -ne 1 ]]; then
        usage >&2
        exit 1
    fi
    dest_vg="$1"

    check_prerequisites

    # 専用のマウント名前空間 (propagation: private) で自分自身を再実行する。
    # ホストの / は shared マウントのため、/mnt 配下へのマウントは systemd サービス等が
    # 持つ別のマウント名前空間 (slave) へも伝播する。特に chroot 用の rbind は、
    # rslave にする前の時点で伝播したコピーがアンマウントされずに残り、
    # 同期先 root LV が「使用中」のままになる。専用名前空間ならどこにも伝播しない。
    if [[ "${SSD_SYNC_IN_NS:-0}" != "1" ]]; then
        command -v unshare >/dev/null || die "コマンドが見つかりません: unshare"
        SSD_SYNC_IN_NS=1 exec unshare --mount --propagation private -- \
            "${BASH_SOURCE[0]}" "${orig_args[@]}"
    fi

    # 多重起動防止 (fd 9 をロックファイルに割り当てて flock)
    exec 9>"${lock_file}"
    flock -n 9 || die "別の ssd-sync が実行中です"

    # rsync 共通オプション
    #   -a: 権限・時刻・リンク等を保持  -H: ハードリンク  -A: ACL  -X: xattr
    #   -x: 別 FS へ降りない  --numeric-ids: UID/GID を数値のまま保持
    rsync_base=(-aHAXx --numeric-ids --delete)
    if (( dry_run )); then
        rsync_base+=(--dry-run --itemize-changes --info=stats1)
    elif [[ -t 1 ]]; then
        rsync_base+=(--info=progress2 --info=stats1)
    else
        rsync_base+=(--info=stats1)
    fi

    # 以降の出力は画面とログの両方へ
    exec > >(tee -a "${log_file}") 2>&1

    trap cleanup EXIT
    trap 'exit 130' INT TERM

    log "===== ssd-sync 開始 (dest=${dest_vg}, snap=${snap_size}, dry_run=${dry_run}) ====="
    detect_source
    check_role
    check_volumes
    mkdir -p "${snap_mnt}" "${sub_mnt}"
    activate_dest
    mount_dest_root
    create_snapshot
    sync_root
    check_snapshot
    remove_snapshot
    sync_boot
    if (( dry_run )); then
        log "ドライランのためブートローダ更新をスキップ"
    else
        update_bootloader
        write_stamp
    fi
}

main "$@"
