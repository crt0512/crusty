#!/system/bin/sh
# replaces crestrons startlighttpd.sh (init service "lighttpd", so init runs it, not you).
# starts right away with our config instead of waiting around for crestrons CPH daemon and its auth/redirect setup.
mkdir -p /dev/shm/web
exec /system/bin/lighttpd -D -f /system/etc/crusty/lighttpd.conf
