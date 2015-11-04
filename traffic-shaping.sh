#! /bin/bash

################################################################################
#
# Cargar variables de configuración
#
########
# Prefijo de red
NET="172.16"

# Interfaces interna y externa
LAN="green0"
WAN="red0"

# Velocidad total de subida de la conexión
UPLINK="960kbit"

# Velocidad total de bajada de la conexión
DOWNLINK="15mbit"

# Porcentaje de utilización máxima de los canales de subida/bajada
MAX_USE=90

# Límites para las clases de prioridad (porcentaje)
EXTRA_MIN=37
HIGH_MIN=30
NORMAL_MIN=23
LOW_MIN=10

EXTRA_MAX=100
HIGH_MAX=`echo  "100 * $HIGH_MIN / $EXTRA_MIN" | bc -l | xargs printf "%.2f"`
NORMAL_MAX=`echo  "100 * $NORMAL_MIN / $EXTRA_MIN" | bc -l | xargs printf "%.2f"`
LOW_MAX=`echo  "100 * $LOW_MIN / $EXTRA_MIN" | bc -l | xargs printf "%.2f"`

#EXTRA_MAX=100
#HIGH_MAX=85
#NORMAL_MAX=60
#LOW_MAX=25



### CÁLCULOS ###################################################################
UP_NUM=`echo $UPLINK | sed 's/[^0-9]//g'`
UP_UNITS=`echo $UPLINK | sed 's/[0-9]//g'`
DOWN_NUM=`echo $DOWNLINK | sed 's/[^0-9]//g'`
DOWN_UNITS=`echo $DOWNLINK | sed 's/[0-9]//g'`

UP_LIMIT=`echo  "$UP_NUM * $MAX_USE / 100" | bc -l | xargs printf "%.2f"`
DOWN_LIMIT=`echo  "$DOWN_NUM * $MAX_USE / 100" | bc -l | xargs printf "%.2f"`

UP_RATE="$UP_LIMIT$UP_UNITS"
DOWN_RATE="$DOWN_LIMIT$DOWN_UNITS"

UP_ACKS=`echo  "$DOWN_LIMIT * 1024 / 56" | bc -l | xargs printf "%.2f$UP_UNITS"`
AVG_RATE=`echo  "($UP_LIMIT - ($DOWN_LIMIT * 1024 / 56)) / 3" | bc -l | xargs printf "%.2f$UP_UNITS"`

EXTRA_RATE=`echo  "$DOWN_LIMIT * $EXTRA_MIN / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
HIGH_RATE=`echo   "$DOWN_LIMIT * $HIGH_MIN / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
NORMAL_RATE=`echo "$DOWN_LIMIT * $NORMAL_MIN / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
LOW_RATE=`echo    "$DOWN_LIMIT * $LOW_MIN / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`

EXTRA_CEIL=`echo  "$DOWN_LIMIT * $EXTRA_MAX / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
HIGH_CEIL=`echo   "$DOWN_LIMIT * $HIGH_MAX / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
NORMAL_CEIL=`echo "$DOWN_LIMIT * $NORMAL_MAX / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`
LOW_CEIL=`echo    "$DOWN_LIMIT * $LOW_MAX / 100" | bc -l | xargs printf "%.2f$DOWN_UNITS"`

echo -e "*** Modelado de Tráfico ***\n"
echo -e "Capacidad Total (bajada/subida): $DOWNLINK/$UPLINK"
echo -e "Límite de Uso (bajada/subida):   $DOWN_RATE/$UP_RATE"
echo
echo -e "Clases de Subida:"
echo -e "\t- DNS, ACKs, SYN/FIN/RST:   $UP_ACKS"
echo -e "\t- ICMP, Minimize-Delay/SSH: $AVG_RATE"
echo -e "\t- Tráfico subida HTTP:      $AVG_RATE"
echo -e "\t- Tráfico subida HTTPS:     $AVG_RATE"
echo
echo -e "Clases de Bajada:"
echo -e "\t- Extra:  $EXTRA_RATE - $EXTRA_CEIL"
echo -e "\t- Alta:   $HIGH_RATE - $HIGH_CEIL"
echo -e "\t- Normal: $NORMAL_RATE - $NORMAL_CEIL"
echo -e "\t- Baja:   $LOW_RATE - $LOW_CEIL"
echo -e "\n"


### PREPARATIVOS ###############################################################
# Borrar reglas de la tabla magle
iptables -t mangle -F POSTROUTING

# Borrar la qdisc ingress de WAN
#tc qdisc del dev $WAN ingress

### Limitación del caudal máximo de entrada desde Internet (INGRESS)
#tc qdisc add dev $WAN handle ffff: ingress

# Priorizar SSH
#tc filter add dev $WAN parent ffff: protocol ip prio 1 u32 match ip sport 22 0xffff flowid :1
#tc filter add dev $WAN parent ffff: protocol ip prio 1 u32 match ip dport 22 0xffff flowid :1

# Limitar el resto
#tc filter add dev $WAN parent ffff: protocol ip prio 50 \
#	u32 match ip src 0.0.0.0/0 police rate ${DOWNLINK}mbit burst 200k drop flowid :2



### UPLOAD #####################################################################
# Borrar la qdisc raiz de WAN
tc qdisc del dev $WAN root

# Añadir la qdisc primaria
tc qdisc add dev $WAN root handle 1:0 htb default 5

# Añadir clase primaria
tc class add dev $WAN parent 1:0 classid 1:1 htb rate ${UP_RATE}

# Añadir subclases dentro de la primaria
# Para ACKs de 52 bytes, la razón entre bytes descargados
# por cada byte enviado para las ACKs es de 56 a 1 (1 ACK por cada 2 paquetes de 1460)
# 256 Kbps de subida para ACKs son suficientes para mantener una descarga de 14 Mbps
# Windows utiliza ACKs de 40 bytes, Linux de 52 bytes
# http://wand.net.nz/~perry/max_download.php
tc class add dev $WAN parent 1:1 classid 1:2 htb rate ${UP_ACKS}  ceil ${UP_RATE} prio 1
tc class add dev $WAN parent 1:1 classid 1:3 htb rate ${AVG_RATE} ceil ${UP_RATE} prio 2
tc class add dev $WAN parent 1:1 classid 1:4 htb rate ${AVG_RATE} ceil ${UP_RATE} prio 3
tc class add dev $WAN parent 1:1 classid 1:5 htb rate ${AVG_RATE} ceil ${UP_RATE} prio 4

# Asignar una algoritmo de planificación para cada subclase
tc qdisc add dev $WAN parent 1:2 sfq perturb 10
tc qdisc add dev $WAN parent 1:3 sfq perturb 10
tc qdisc add dev $WAN parent 1:4 sfq perturb 10
tc qdisc add dev $WAN parent 1:5 sfq perturb 10

# Indicar que todos los paquetes marcados con X sigan el flujo 1:X
tc filter add dev $WAN parent 1:0 protocol ip prio 1 handle 2 fw flowid 1:2
tc filter add dev $WAN parent 1:0 protocol ip prio 1 handle 3 fw flowid 1:3
tc filter add dev $WAN parent 1:0 protocol ip prio 1 handle 4 fw flowid 1:4
tc filter add dev $WAN parent 1:0 protocol ip prio 1 handle 5 fw flowid 1:5

### UPLOAD classification ######################################################
# Clase 2 - DNS, ACKs sin payload (40+0) o muy pequeño (hasta 40+12)
CLASS=2
iptables -t mangle -A POSTROUTING -o $WAN -p udp --dport 53 -m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $WAN -p tcp --dport 53 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -p tcp --syn \
	-m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK SYN,ACK \
	-m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK RST \
	-m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK RST,ACK \
	-m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK FIN \
	-m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK FIN,ACK \
	-m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -p tcp --tcp-flags FIN,SYN,RST,ACK ACK -m length --length :52 \
	-m mark --mark 0 -j MARK --set-mark $CLASS


# Clase 3 - ICMP, ToS Minimize-Delay, SSH y ACKs con payload bajo (1500/5)
CLASS=3
iptables -t mangle -A POSTROUTING -o $WAN -p icmp -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -m tos --tos Minimize-Delay -m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $WAN -p tcp --dport 22 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $WAN -p tcp  -m mark --mark 0 \
	--tcp-flags FIN,SYN,RST,ACK ACK -m length --length :300 -j MARK --set-mark $CLASS


# Clase 4 - HTTP (y ACKs con payload alto)
CLASS=4
iptables -t mangle -A POSTROUTING -o $WAN -p tcp -m multiport --dports 80,8080 -m mark --mark 0 -j MARK --set-mark $CLASS


# Clase 5 - HTTPS (y ACKs con payload alto)
CLASS=5
iptables -t mangle -A POSTROUTING -o $WAN -p tcp -m multiport --dports 443,8443 -m mark --mark 0 -j MARK --set-mark $CLASS



### DOWNLOAD ###################################################################
# Borrar la qdisc raiz de LAN
tc qdisc del dev $LAN root

# Añadir la qdisc primaria
tc qdisc add dev $LAN root handle 1:0 htb default 5

# Añadir clase primaria
tc class add dev $LAN parent 1:0 classid 1:1 htb rate ${DOWN_RATE}

# Añadir subclases dentro de la primaria
# Las clases con valor de prioridad más bajo se satisfacen primero haciendo un round robin, luego el resto
# El exceso de ancho de banda se repartirá entre todas las clases que tengan la misma prioridad
tc class add dev $LAN parent 1:1 classid 1:2 htb rate ${EXTRA_RATE}  ceil ${EXTRA_CEIL}  prio 1
tc class add dev $LAN parent 1:1 classid 1:3 htb rate ${HIGH_RATE}   ceil ${HIGH_CEIL}   prio 1
tc class add dev $LAN parent 1:1 classid 1:4 htb rate ${NORMAL_RATE} ceil ${NORMAL_CEIL} prio 1
tc class add dev $LAN parent 1:1 classid 1:5 htb rate ${LOW_RATE}    ceil ${LOW_CEIL}    prio 1

# Asignar una algoritmo de planificación para cada subclase
tc qdisc add dev $LAN parent 1:2 sfq perturb 10
tc qdisc add dev $LAN parent 1:3 sfq perturb 10
tc qdisc add dev $LAN parent 1:4 sfq perturb 10
tc qdisc add dev $LAN parent 1:5 sfq perturb 10

# Indicar que todos los paquetes marcados con X sigan el flujo 1:X
tc filter add dev $LAN parent 1:0 protocol ip prio 1 handle 2 fw flowid 1:2
tc filter add dev $LAN parent 1:0 protocol ip prio 1 handle 3 fw flowid 1:3
tc filter add dev $LAN parent 1:0 protocol ip prio 1 handle 4 fw flowid 1:4
tc filter add dev $LAN parent 1:0 protocol ip prio 1 handle 5 fw flowid 1:5

### DOWNLOAD classification ####################################################
# Prioridad 2-Extra -- Equipos críticos, DNS, SSH y Telnet
CLASS=2
iptables -t mangle -A POSTROUTING -o $LAN -p tcp -d $NET.0.0/24 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $LAN -p tcp --sport 53 -m mark --mark 0 -j MARK --set-mark $CLASS
iptables -t mangle -A POSTROUTING -o $LAN -p udp --sport 53 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m multiport \
	--sports 22,23 -m mark --mark 0 -j MARK --set-mark $CLASS


# Prioridad 3-Alta -- HTTP
# El proxy intercepta el tráfico por los puertos 800 y 801 en los modos no transparente y transparente respectivamente
CLASS=3
iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m multiport \
	--sports 80,800,801,8080 -m mark --mark 0 -j MARK --set-mark $CLASS


# Prioridad 4-Normal -- HTTPS, FTP
CLASS=4
iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m multiport \
	--sports 443,8443 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m multiport \
	--sports 20,21 -m mark --mark 0 -j MARK --set-mark $CLASS


# Prioridad 5-Baja -- EMAIL y cualquier otra cosa
CLASS=5
iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m multiport \
	--sports 25,110,143,465,587,993,995 -m mark --mark 0 -j MARK --set-mark $CLASS

iptables -t mangle -A POSTROUTING -o $LAN -p tcp -m mark --mark 0 -j MARK --set-mark $CLASS
