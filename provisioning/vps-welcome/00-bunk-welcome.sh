# Toont het welkomstscherm precies één keer per gebruiker.
#
# In profile.d en niet in update-motd.d: die laatste draait als root en heeft
# geen betrouwbare $HOME, en het merkteken hoort bij de persoon die inlogt, niet
# bij de machine. Een tweede account op dezelfde VPS krijgt zijn eigen eerste
# keer.
if [ -n "$HOME" ] && [ ! -e "$HOME/.bunk-welcome-seen" ] && [ -x /etc/bunk/welcome ]; then
    /etc/bunk/welcome
    : > "$HOME/.bunk-welcome-seen" 2>/dev/null || true
fi
