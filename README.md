# traffic-shaping

Script para el modelado de tráfico a medida a través de un proxy transparente basado en IPFire.

El algoritmo utilizado para el reparto del ancho de banda es el HTB. Se utilizan colas SFQ para la planificación en las distintas subclases.