on run argv
    if (count of argv) is not 2 then error "Faltan los datos de instalación."
    set installerPath to item 1 of argv
    set expectedHash to item 2 of argv
    set quotedPath to quoted form of installerPath
    set quotedHash to quoted form of expectedHash
    set commandLine to "set -e; installer=$(/usr/bin/mktemp /private/var/tmp/nuvex-installer.XXXXXX); trap 'rm -f \"$installer\"' EXIT; /bin/cp " & quotedPath & " \"$installer\"; test \"$(/usr/bin/shasum -a 256 \"$installer\" | /usr/bin/awk '{print $1}')\" = " & quotedHash & "; /bin/bash \"$installer\""
    do shell script commandLine with administrator privileges
end run
