#!/bin/sh
# Starts the Phorge daemons in the foreground, so that supervisord can watch
# them. "bin/phd start" cannot be used for this: it detaches the daemons from
# the calling process.
#
# The steps follow executeStartCommand() and launchDaemons() in
# src/applications/daemon/management/PhabricatorDaemonManagementWorkflow.php
# of Phorge.
set -eu

cd /opt/phorge/phorge

# "bin/phd start" first releases the tasks that the previous daemons had
# reserved and did not finish, so that the new daemons pick them up at once.
bin/worker free --active

# The same daemons that "bin/phd start" launches. The keys "daemonize" and
# "log" are left out: without them the process stays in the foreground and
# writes its log to the standard error stream.
config=$(php -r '
    require_once "scripts/__init_script__.php";
    echo json_encode(array(
        "daemons" => array(
            array(
                "class" => "PhabricatorRepositoryPullLocalDaemon",
                "label" => "pull",
            ),
            array(
                "class" => "PhabricatorTriggerDaemon",
                "label" => "trigger",
            ),
            array(
                "class" => "PhabricatorFactDaemon",
                "label" => "fact",
            ),
            array(
                "class" => "PhabricatorTaskmasterDaemon",
                "label" => "task",
                "pool" => PhabricatorEnv::getEnvConfig("phd.taskmasters"),
                "reserve" => 0,
            ),
        ),
    ));
')

cd scripts/daemon

exec ./phd-daemon <<EOF
$config
EOF
