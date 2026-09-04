# shellcheck shell=bash
# lib/lock.sh — tvånivålåsning. Måste sitta rätt från början (PLAN.md §6).
#
#   Globalt lås  (/var/lock/lxc-offsite.global)
#     Släpper igenom EXAKT en backup/push-operation åt gången, oavsett vmid.
#     Skäl: två samtidiga vzdump --mode snapshot mot raidz2 straffar körande
#     containrar. fetch/restore tar ALDRIG detta lås — de skriver inte från poolen.
#
#   Per-vmid-lås (/var/lock/lxc-offsite.vmid-<vmid>.lock)
#     Hindrar att samma container köas/körs två gånger.
#
#   Lägen:
#     queue  — schemalagd körning: väntar på globala låset upp till
#              GLOBAL_LOCK_TIMEOUT, avslutar sedan med fel (blir en kö man SER).
#     now    — manuell körning: avslutar direkt med besked om VAD som blockerar
#              och HUR LÄNGE (en tyst köad manuell körning = förvirring).
#
# Låsen släpps automatiskt när processen dör (fd stängs) — holder-filen städas
# i cleanup_locks via EXIT-trap.

GLOBAL_LOCK_HELD=0
VMID_LOCK_HELD=0
GLOBAL_LOCK_FD=""
VMID_LOCK_FD=""

# Skriv/las holder-metadata så `status` och now-läget kan visa vem som blockerar.
_write_global_holder() {
    local op="$1" vmid="$2"
    printf '%s|%s|%s|%s\n' "${vmid:-none}" "$op" "$$" "$(date +%s)" \
        > "$GLOBAL_HOLDER_FILE" 2>/dev/null || true
}

# Returnerar en läsbar beskrivning av globala lås-hållaren, eller tom sträng.
read_global_holder() {
    [[ -f "$GLOBAL_HOLDER_FILE" ]] || { printf ''; return; }
    local line vmid op pid since now age
    line="$(<"$GLOBAL_HOLDER_FILE")"
    IFS='|' read -r vmid op pid since <<<"$line"
    now="$(date +%s)"; age=$(( now - ${since:-now} ))
    printf 'vmid=%s op=%s pid=%s sedan=%ss' "$vmid" "$op" "$pid" "$age"
}

# acquire_global_lock <queue|now> <op> [vmid]
acquire_global_lock() {
    local mode="$1" op="$2" vmid="${3:-}"
    exec {GLOBAL_LOCK_FD}>"$GLOBAL_LOCK_FILE" \
        || die "$EX_CANTCREAT" "kan inte öppna global låsfil: $GLOBAL_LOCK_FILE"

    if [[ "$mode" == "queue" ]]; then
        log_info "väntar på globalt lås (kö, timeout ${GLOBAL_LOCK_TIMEOUT}s)…"
        if ! flock -w "$GLOBAL_LOCK_TIMEOUT" "$GLOBAL_LOCK_FD"; then
            local h; h="$(read_global_holder)"
            die "$EX_TEMPFAIL" "globalt lås ej erhållet inom ${GLOBAL_LOCK_TIMEOUT}s (hålls av: ${h:-okänt})"
        fi
    else
        if ! flock -n "$GLOBAL_LOCK_FD"; then
            local h; h="$(read_global_holder)"
            die "$EX_TEMPFAIL" "globalt lås upptaget — en operation kör redan (${h:-okänt}). Avslutar (manuellt läge köar inte)."
        fi
    fi

    GLOBAL_LOCK_HELD=1
    _write_global_holder "$op" "$vmid"
    log_info "globalt lås erhållet (op=$op vmid=${vmid:-none})."
}

# acquire_vmid_lock <vmid>  — icke-blockerande; dubbelköning är alltid ett fel.
acquire_vmid_lock() {
    local vmid="$1"
    local f="${LOCK_DIR}/lxc-offsite.vmid-${vmid}.lock"
    exec {VMID_LOCK_FD}>"$f" \
        || die "$EX_CANTCREAT" "kan inte öppna vmid-låsfil: $f"
    if ! flock -n "$VMID_LOCK_FD"; then
        die "$EX_TEMPFAIL" "vmid $vmid är redan köad eller körs — hoppar över."
    fi
    VMID_LOCK_HELD=1
    log_info "vmid-lås erhållet för $vmid."
}

# Städa lås + holder-fil. Sätts som EXIT-trap av huvudscriptet.
cleanup_locks() {
    if [[ "${GLOBAL_LOCK_HELD:-0}" == 1 ]]; then
        rm -f "$GLOBAL_HOLDER_FILE" 2>/dev/null || true
        [[ -n "$GLOBAL_LOCK_FD" ]] && flock -u "$GLOBAL_LOCK_FD" 2>/dev/null || true
    fi
    [[ "${VMID_LOCK_HELD:-0}" == 1 && -n "$VMID_LOCK_FD" ]] && flock -u "$VMID_LOCK_FD" 2>/dev/null || true
}
