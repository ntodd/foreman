#!/bin/sh
set -e

on_exit () {
	[ $? -eq 0 ] && exit
	echo 'ERROR: Feature "./second" (Unknown) failed to install!'
}

trap on_exit EXIT

echo ===========================================================================

echo 'Feature       : ./second'
echo 'Description   : '
echo 'Id            : Unknown'
echo 'Version       : 0.1.0'
echo 'Documentation : '
echo 'Options       :'
echo ''
echo ===========================================================================

set -a
. ../devcontainer-features.builtin.env
. ./devcontainer-features.env
set +a

chmod +x ./install.sh
./install.sh
