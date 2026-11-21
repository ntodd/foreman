#!/bin/sh
set -e

on_exit () {
	[ $? -eq 0 ] && exit
	echo 'ERROR: Feature "Local '\''Feature'\''" (Unknown) failed to install! Look at the documentation at https://example.com/docs for help troubleshooting this error.'
}

trap on_exit EXIT

echo ===========================================================================

echo 'Feature       : Local '\''Feature'\'''
echo 'Description   : It'\''s a test'
echo 'Id            : Unknown'
echo 'Version       : 1.0.0'
echo 'Documentation : https://example.com/docs'
echo 'Options       :'
echo '    ZETA="z"
    GREETING="hi there"
    LOUD="true"'
echo ===========================================================================

set -a
. ../devcontainer-features.builtin.env
. ./devcontainer-features.env
set +a

chmod +x ./install.sh
./install.sh
