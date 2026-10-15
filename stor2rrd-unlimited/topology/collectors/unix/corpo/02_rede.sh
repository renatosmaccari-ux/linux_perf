# ============================================================
# 02-REDE: interfaces, IPs, VLAN, rotas, DNS, classificacao de rede
# Atende: 1d (parte que existe no SO)
# ============================================================

if [ "$PLAT" = aix ]; then
  for i in $(run 20 ifconfig -l 2>/dev/null); do
    [ "$i" = "lo0" ] && continue
    _if=$(run 10 ifconfig "$i" 2>/dev/null)
    _ip=$(printf '%s\n' "$_if" | awk '/inet /{print $2; exit}')
    _mk=$(printf '%s\n' "$_if" | awk '/inet /{print $4; exit}')
    _st=$(printf '%s\n' "$_if" | awk 'NR==1{if(index($0,"UP"))print "up"; else print "down"}')
    emit rede "$i" ip       "$_ip"
    emit rede "$i" netmask  "$_mk"
    emit rede "$i" prefixo  "$( [ -n "$_mk" ] && printf '/%s' "$(hex2cidr "$_mk")" )"
    emit rede "$i" cidr     "$( [ -n "$_ip" ] && [ -n "$_mk" ] && printf '%s/%s' "$_ip" "$(hex2cidr "$_mk")" )"
    emit rede "$i" estado   "$_st"
    emit rede "$i" mtu      "$(printf '%s\n' "$_if" | sed -n '1s/.*mtu \([0-9]*\).*/\1/p')"
    case "$i" in
      en*|et*)
        _e=$(echo "$i" | sed 's/^en/ent/;s/^et/ent/')
        emit rede "$i" adaptador   "$_e"
        emit rede "$i" mac         "$(run 15 entstat -d "$_e" 2>/dev/null | awk -F': ' '/Hardware Address/{print $2; exit}')"
        _es=$(run 20 entstat -d "$_e" 2>/dev/null)
        emit rede "$i" velocidade  "$(printf '%s\n' "$_es" | awk -F': ' '/Media Speed Running/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
        emit rede "$i" port_vlan_id "$(printf '%s\n' "$_es" | awk -F': ' '/Port VLAN ID/{gsub(/[ \t]/,"",$2); print $2; exit}')"
        emit rede "$i" vlan_tags_ext "$(printf '%s\n' "$_es" | awk -F': ' '/VLAN Tag IDs|Switch ID/{gsub(/^[ \t]+/,"",$2); printf "%s ", $2}')"
        emit rede "$i" vlan_tag    "$(run 15 lsattr -El "$_e" -a vlan_tag_id 2>/dev/null | awk '{print $2}')"
        emit rede "$i" tipo_virt   "$(run 15 lsdev -Cl "$_e" 2>/dev/null | sed 's/.*  //')"
        ;;
    esac
  done
  emit rede rota gateway_default "$(run 15 netstat -rn 2>/dev/null | awk '$1=="default"{print $2; exit}')"
  # Somente rotas de REDE: descarta host, broadcast, loopback e rotas locais
  run 15 netstat -rn 2>/dev/null | \
    awk '$1!="default" && $1 ~ /^[0-9]/ && $3 ~ /^U/ && $3 !~ /H/ && $1 !~ /^127/ && $1 ~ /\// {print $1"|"$2}' | \
    while IFS='|' read d g; do emit rede rota_rede "$d" "$g"; done
elif [ "$PLAT" = solaris ]; then
  # Enderecos IP (ipadm e a fonte autoritativa no Solaris 11).
  # Em zona shared-IP o ipadm existe mas nao devolve nada: sonda antes de decidir.
  _IPADM=""
  has ipadm && _IPADM=$(run 20 ipadm show-addr -p -o ADDROBJ,TYPE,STATE,ADDR 2>/dev/null)
  if [ -n "$_IPADM" ]; then
    printf '%s\n' "$_IPADM" | \
      while IFS=: read ao tp st ad; do
        [ -n "$ao" ] || continue
        _i=$(printf '%s' "$ao" | sed 's|/.*||')
        case "$_i" in lo0) continue ;; esac
        emit rede "$_i" ip_cidr    "$ad"
        emit rede "$_i" addrobj    "$ao"
        emit rede "$_i" tipo_addr  "$tp"
        emit rede "$_i" estado     "$st"
      done
  else
    run 20 ifconfig -a 2>/dev/null | $AWK '/^[a-z]/{i=$1; sub(/:$/,"",i)} /inet /{if ($2 !~ /^127\./) print i"|"$2"|"$4}' | \
      while IFS='|' read i ip mk; do
        emit rede "$i" ip "$ip"; emit rede "$i" netmask "$mk"
        emit rede "$i" prefixo "/$(hex2cidr "$mk")"
        emit rede "$i" cidr "$ip/$(hex2cidr "$mk")"
      done
  fi
  # Camada de enlace: so a global enxerga os links fisicos
  if [ "$ZONA_TIPO" != global ]; then
    emit rede escopo aviso "zona nao-global: dladm/enlace fisico visivel apenas na global"
  fi
  # Camada de enlace: MAC, velocidade, estado, driver
  run 25 dladm show-phys -p -o LINK,MEDIA,STATE,SPEED,DUPLEX,DEVICE 2>/dev/null | \
    while IFS=: read lk md st sp dx dv; do
      [ -n "$lk" ] || continue
      emit rede "$lk" midia      "$md"
      emit rede "$lk" estado_link "$st"
      emit rede "$lk" velocidade "$sp"
      emit rede "$lk" duplex     "$dx"
      emit rede "$lk" adaptador  "$dv"
    done
  run 20 dladm show-phys -m -p -o LINK,ADDRESS 2>/dev/null | \
    while IFS=: read lk ad; do [ -n "$lk" ] && emit rede "$lk" mac "$ad"; done
  run 20 dladm show-vlan -p -o LINK,VID,OVER 2>/dev/null | \
    while IFS=: read lk vid ov; do
      [ -n "$lk" ] || continue
      emit rede "$lk" vlan_tag "$vid"; emit rede "$lk" vlan_sobre "$ov"
    done
  run 20 dladm show-aggr -p -o LINK,POLICY,LACPACTIVITY 2>/dev/null | \
    while IFS=: read lk po la; do
      [ -n "$lk" ] || continue
      emit rede "$lk" aggr_politica "$po"; emit rede "$lk" aggr_lacp "$la"
      emit rede "$lk" aggr_portas "$(run 15 dladm show-aggr -x -p -o PORT "$lk" 2>/dev/null | tr '\n' ' ')"
    done
  run 20 dladm show-link -p -o LINK,CLASS,MTU 2>/dev/null | \
    while IFS=: read lk cl mt; do
      [ -n "$lk" ] || continue
      emit rede "$lk" classe "$cl"; emit rede "$lk" mtu "$mt"
    done
  # IPMP (alta disponibilidade de rede, comum no parque Solaris)
  run 20 ipmpstat -g -P -o GROUP,STATE,INTERFACES 2>/dev/null | \
    while IFS=: read g st ifs; do [ -n "$g" ] && emit rede ipmp "$g" "$st ($ifs)"; done
  emit rede rota gateway_default "$(run 15 netstat -rn -f inet 2>/dev/null | $AWK '$1=="default"{print $2; exit}')"
  run 15 netstat -rn -f inet 2>/dev/null | \
    $AWK '$1!="default" && $1 ~ /^[0-9]/ && $1 !~ /^127/ && NF>=2 {print $1"|"$2}' | \
    while IFS='|' read d g; do emit rede rota_rede "$d" "$g"; done
else
  for i in $(run 15 ls /sys/class/net 2>/dev/null); do
    [ "$i" = "lo" ] && continue
    _ip=$(run 10 ip -o -4 addr show "$i" 2>/dev/null | awk '{print $4; exit}')
    emit rede "$i" ip_cidr    "$_ip"
    emit rede "$i" estado     "$(cat /sys/class/net/$i/operstate 2>/dev/null)"
    emit rede "$i" mac        "$(cat /sys/class/net/$i/address 2>/dev/null)"
    emit rede "$i" mtu        "$(cat /sys/class/net/$i/mtu 2>/dev/null)"
    emit rede "$i" velocidade "$(cat /sys/class/net/$i/speed 2>/dev/null)"
    [ -f "/proc/net/vlan/$i" ] && \
      emit rede "$i" vlan_tag "$(awk -F'  +' '/VID:/{print $2}' /proc/net/vlan/$i 2>/dev/null | awk '{print $1}')"
    [ -d "/sys/class/net/$i/bonding" ] && \
      emit rede "$i" bond_slaves "$(cat /sys/class/net/$i/bonding/slaves 2>/dev/null)"
    [ -d "/sys/class/net/$i/bonding" ] && \
      emit rede "$i" bond_modo   "$(awk '{print $1}' /sys/class/net/$i/bonding/mode 2>/dev/null)"
  done
  # Posicional falha: "default dev eth0" nao tem gateway em $3. Le por palavra-chave.
  emit rede rota gateway_default "$(run 10 ip route show default 2>/dev/null | \
    $AWK '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  emit rede rota iface_default "$(run 10 ip route show default 2>/dev/null | \
    $AWK '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  run 10 ip route show 2>/dev/null | $AWK '$1!="default" && NF>2 {
      gw=""; dev=""
      for(i=1;i<=NF;i++){ if($i=="via") gw=$(i+1); if($i=="dev") dev=$(i+1) }
      print $1"|"(gw!="" ? gw : "direto:" dev)
    }' | while IFS='|' read d g; do emit rede rota_estatica "$d" "$g"; done
fi

# DNS / resolucao / dominio
emit rede dns servidores "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
emit rede dns dominio    "$(awk '/^(domain|search)/{$1=""; print; exit}' /etc/resolv.conf 2>/dev/null | sed 's/^ //')"
emit rede ntp servidores "$($AWK '/^(server|pool|peer)/{printf "%s ", $2}' /etc/ntp.conf /etc/chrony.conf /etc/chrony/chrony.conf /etc/inet/ntp.conf 2>/dev/null)"

# Portas em escuta (evidencia de servicos expostos)
case "$PLAT" in
  solaris)
    run 30 netstat -an -f inet -P tcp 2>/dev/null | \
      $AWK '$NF=="LISTEN" && $1 ~ /\.[0-9]+$/ {p=$1; sub(/.*\./,"",p); print p}' | sort -un | \
      while read p; do emit rede portas listen_tcp "$p"; done
    ;;
  aix)
    run 30 netstat -an -f inet 2>/dev/null | $AWK '/LISTEN/{print $4}' | sed 's/.*\.//' | sort -un | \
      while read p; do emit rede portas listen_tcp "$p"; done
    ;;
  *)
    # Sem filtro de familia: mantem o comportamento original (inclui tcp6)
    if has ss; then
      run 30 ss -ltnH 2>/dev/null | $AWK '{print $4}' | sed 's/.*://' | sort -un | \
        while read p; do emit rede portas listen_tcp "$p"; done
    elif has netstat; then
      run 30 netstat -an 2>/dev/null | $AWK '/LISTEN/{print $4}' | sed 's/.*[.:]//' | sort -un | \
        while read p; do emit rede portas listen_tcp "$p"; done
    fi
    ;;
esac
exit 0
