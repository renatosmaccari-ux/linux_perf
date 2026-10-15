#!/bin/sh
# ============================================================
# hmc_collect.sh v2 - Coleta nas HMCs. RODA NO BASTION, nao na HMC.
#
# A HMC usa bash restrito (rbash): nao permite redirecionamento (2>/dev/null),
# nao tem 'tr', 'sed', 'grep' no PATH e bloqueia atribuicao de PATH. Por isso
# NAO se envia script para dentro dela. Aqui cada comando HMC e executado
# isoladamente via ssh e toda a formatacao acontece no bastion.
#
# Uso: ./hmc_collect.sh -o 06_hmc.csv [-l hmcs.txt] [-u hscroot] [-t 30]
# ============================================================
set -u

OUT="06_hmc.csv"
HMCS=""
HMC_USER="${HMC_USER:-hscroot}"
CT=30
# Sem padrao embutido: as HMCs vem de -l, da variavel HMC_LIST, ou do
# proprio LPAR2RRD (etc/web_config/hosts.json). Um IP fixo aqui so
# funcionaria no ambiente onde o kit nasceu.
LISTA_PADRAO="${HMC_LIST:-}"

while getopts "o:l:u:t:h" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    l) HMCS="$OPTARG" ;;
    u) HMC_USER="$OPTARG" ;;
    t) CT="$OPTARG" ;;
    *) echo "uso: $0 -o saida.csv [-l hmcs.txt] [-u usuario] [-t timeout]" >&2; exit 2 ;;
  esac
done

if [ -n "$HMCS" ] && [ -r "$HMCS" ]; then
  LISTA=$(awk 'NF && $1 !~ /^#/ {print $1}' "$HMCS")
else
  LISTA="$LISTA_PADRAO"
fi

WD="${OUT%.csv}.work"
rm -rf "$WD"; mkdir -p "$WD" || exit 1

echo "hmc,categoria,item,chave,valor" > "$OUT"
ERR="${OUT%.csv}_falhas.csv"
echo "hmc,motivo" > "$ERR"

# Executa um comando na HMC. Toda a saida vem crua; nada e redirecionado la.
hx() {
  _h="$1"; _c="$2"
  ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout="$CT" -o ConnectionAttempts=1 \
      "$HMC_USER@$_h" "$_c" 2>>"$WD/$_h.err"
}

# Emite CSV escapando o campo valor
em() {
  [ -n "${5:-}" ] || return 0
  printf '%s,%s,%s,%s,"%s"\n' "$1" "$2" "$3" "$4" \
    "$(printf '%s' "$5" | tr -d '\r' | sed 's/"/""/g')" >> "$OUT"
}

for H in $LISTA; do
  echo "===== HMC $H ====="
  : > "$WD/$H.err"

  if ! hx "$H" "lshmc -V" > "$WD/$H.ver"; then
    MOTIVO=$(head -1 "$WD/$H.err" | tr -d '\r' | tr ',' ' ' | cut -c1-120)
    echo "[FALHA] $H - $MOTIVO" >&2
    echo "$H,\"${MOTIVO:-ssh_falhou}\"" >> "$ERR"
    continue
  fi
  echo "[OK] $H conectada"

  # ---------- identificacao e rede da HMC (1d) ----------
  awk -v h="$H" 'NF{gsub(/"/,"\"\"");print h",hmc,versao,linha,\""$0"\""}' "$WD/$H.ver" >> "$OUT"
  for c in ipaddr gateway nameserver domain; do
    em "$H" hmc rede "$c" "$(hx "$H" "lshmc -n -F $c")"
  done
  em "$H" hmc rede ntp "$(hx "$H" "lshmc -r -F xntp")"

  # ---------- Call Home / SMTP (1f) ----------
  em "$H" callhome estado connmon "$(hx "$H" "lshmc -r -F connmon")"
  hx "$H" "lshmc -r" > "$WD/$H.svc"
  awk -v h="$H" 'NF{n=split($0,a,",");for(i=1;i<=n;i++){s=index(a[i],"=");
    if(s>0){k=substr(a[i],1,s-1);v=substr(a[i],s+1);gsub(/"/,"",v);
      if(v!="")print h",callhome,servico,"k",\""v"\""}}}' "$WD/$H.svc" >> "$OUT"
  hx "$H" "lsnotification -t email" > "$WD/$H.notif"
  awk -v h="$H" 'NF{gsub(/"/,"\"\"");print h",smtp,notificacao,destino,\""$0"\""}' "$WD/$H.notif" >> "$OUT"

  # ---------- usuarios e politica de senha da HMC (1e, 4) ----------
  hx "$H" "lshmcusr -F name:taskrole:resourcerole:pwage:description" > "$WD/$H.usr"
  awk -F: -v h="$H" 'NF>=4{gsub(/"/,"",$5);
    print h",usuario,"$1",taskrole,\""$2"\"";
    print h",usuario,"$1",resourcerole,\""$3"\"";
    print h",usuario,"$1",pwage_dias,\""$4"\"";
    if($5!="") print h",usuario,"$1",descricao,\""$5"\""}' "$WD/$H.usr" >> "$OUT"
  hx "$H" "lshmcusr -t pwdpolicy" > "$WD/$H.pwd"
  awk -v h="$H" 'NF{n=split($0,a,",");for(i=1;i<=n;i++){s=index(a[i],"=");
    if(s>0){k=substr(a[i],1,s-1);v=substr(a[i],s+1);gsub(/"/,"",v);
      if(v!="")print h",politica_senha,hmc,"k",\""v"\""}}}' "$WD/$H.pwd" >> "$OUT"

  # ---------- sistemas gerenciados (1a,1b,1c) ----------
  hx "$H" "lssyscfg -r sys -F name:type_model:serial_num:state:ipaddr:ipaddr_secondary" > "$WD/$H.sys"
  awk -F: -v h="$H" 'NF>=4{
    print h",sistema,"$1",type_model,\""$2"\"";
    print h",sistema,"$1",serial,\""$3"\"";
    print h",sistema,"$1",estado,\""$4"\"";
    if($5!="")print h",sistema,"$1",fsp_primario,\""$5"\"";
    if($6!="")print h",sistema,"$1",fsp_secundario,\""$6"\""}' "$WD/$H.sys" >> "$OUT"

  for S in $(awk -F: 'NF>=2{print $1}' "$WD/$H.sys"); do
    echo "  - $S"
    em "$H" capacidade "$S" proc \
      "$(hx "$H" "lshwres -r proc -m $S --level sys -F configurable_sys_proc_units:curr_avail_sys_proc_units:installed_sys_proc_units")"
    em "$H" capacidade "$S" mem \
      "$(hx "$H" "lshwres -r mem -m $S --level sys -F configurable_sys_mem:curr_avail_sys_mem:installed_sys_mem")"
    em "$H" firmware "$S" nivel \
      "$(hx "$H" "lslic -m $S -t sys -F ecnumber,activated_level,activated_spname")"
    em "$H" cod "$S" uak \
      "$(hx "$H" "lscod -m $S -t key -k uak -F sequence_num,entry_check,expiration_date")"
    em "$H" cod "$S" proc_perm "$(hx "$H" "lscod -m $S -t cap -r proc -c perm")"
    em "$H" cod "$S" mem_perm  "$(hx "$H" "lscod -m $S -t cap -r mem -c perm")"
    em "$H" cod "$S" onoff_proc "$(hx "$H" "lscod -m $S -t cap -r proc -c onoff")"
    em "$H" localizacao "$S" descricao_hmc "$(hx "$H" "lssyscfg -r sys -m $S -F description")"

    # LPARs vistas pelo HMC (2a, 1d)
    hx "$H" "lssyscfg -r lpar -m $S -F name:lpar_id:state:os_version:rmc_ipaddr:rmc_state:lpar_env" > "$WD/$H.$S.lpar"
    awk -F: -v h="$H" -v s="$S" 'NF>=6{
      print h",lpar,"s"/"$1",id,\""$2"\"";
      print h",lpar,"s"/"$1",estado,\""$3"\"";
      if($4!="")print h",lpar,"s"/"$1",os,\""$4"\"";
      if($5!="")print h",lpar,"s"/"$1",rmc_ip,\""$5"\"";
      print h",lpar,"s"/"$1",rmc_estado,\""$6"\"";
      if($7!="")print h",lpar,"s"/"$1",ambiente,\""$7"\""}' "$WD/$H.$S.lpar" >> "$OUT"

    # VLAN dos adaptadores virtuais (1d) - o dado que so existe no HMC
    hx "$H" "lshwres -r virtualio --rsubtype eth --level lpar -m $S -F lpar_name:slot_num:port_vlan_id:addl_vlan_ids:is_trunk:mac_addr" > "$WD/$H.$S.vlan"
    awk -F: -v h="$H" -v s="$S" 'NF>=3{
      print h",vlan,"s"/"$1",slot"$2"_pvid,\""$3"\"";
      if($4!="")print h",vlan,"s"/"$1",slot"$2"_addl_vlans,\""$4"\"";
      if($5!="")print h",vlan,"s"/"$1",slot"$2"_trunk,\""$5"\"";
      if($6!="")print h",vlan,"s"/"$1",slot"$2"_mac,\""$6"\""}' "$WD/$H.$S.vlan" >> "$OUT"

    hx "$H" "lshwres -r virtualio --rsubtype vswitch -m $S -F vswitch,vlan_ids" > "$WD/$H.$S.vsw"
    awk -v h="$H" -v s="$S" 'NF{gsub(/"/,"\"\"");print h",vswitch,"s",definicao,\""$0"\""}' "$WD/$H.$S.vsw" >> "$OUT"
  done
done

N=$(( $(wc -l < "$OUT" | tr -d ' ') - 1 ))
E=$(( $(wc -l < "$ERR" | tr -d ' ') - 1 ))
echo ""
echo "[RESUMO] linhas: $N | HMCs com falha: $E"
echo "[RESUMO] dados:  $OUT"
[ "$E" -gt 0 ] && echo "[RESUMO] falhas: $ERR"
exit 0
