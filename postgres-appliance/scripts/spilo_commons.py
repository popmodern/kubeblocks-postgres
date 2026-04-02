import logging
import os
import subprocess
import re
import yaml

logger = logging.getLogger('__name__')

RW_DIR = os.environ.get('RW_DIR', '/run')
PATRONI_CONFIG_FILE = os.path.join(RW_DIR, 'postgres.yml')
LIB_DIR = '/usr/lib/postgresql'
SHARE_DIR = '/usr/share/postgresql'

extension_control_files = {
    'vault': 'supabase_vault',
}

# (min_version, max_version, shared_preload_libraries, extwlist.extensions)
extensions = {
    'timescaledb':    (9.6, 17, True,  True),
    'pg_cron':        (9.5, 17, True,  False),
    'pg_stat_kcache': (9.4, 17, True,  False),
    'pg_partman':     (9.4, 17, False, True),
}
if os.environ.get('ENABLE_PG_MON') == 'true':
    extensions['pg_mon'] = (11,  17, True,  False)

if os.environ.get('ENABLE_SUPABASE_EXTENSIONS') == 'true':
    extensions.update({
        'pgsodium':        (14, 17, True,  False),
        'pg_net':          (14, 17, True,  True),
        'pg_tle':          (14, 17, True,  True),
        'pg_stat_monitor': (14, 17, True,  True),
        'pg_plan_filter':  (14, 17, True,  False),
        'supautils':       (14, 17, True,  False),
        'pgjwt':           (14, 17, False, True),
        'pgtap':           (14, 17, False, True),
        'pgmq':            (14, 17, False, True),
        'pg_hashids':      (14, 17, False, True),
        'pg_graphql':      (14, 17, False, True),
        'pg_jsonschema':   (14, 17, False, True),
        'safeupdate':      (14, 17, False, True),
        'vault':           (14, 17, False, True),
        'http':            (14, 17, False, True),
        'rum':             (14, 17, False, True),
        'index_advisor':   (14, 17, False, True),
        'wrappers':        (14, 17, False, True),
        'pgroonga':        (14, 17, False, True),
        'pgrouting':       (14, 17, False, True),
    })


def adjust_extensions(old, version, extwlist=False):
    ret = []
    for name in old.split(','):
        name = name.strip()
        value = extensions.get(name)
        is_supported = value is None or (
            value[0] <= version <= value[1]
            and extension_is_installed(name, version)
            and (not extwlist or value[3])
        )
        if name not in ret and is_supported:
            ret.append(name)
    return ','.join(ret)


def append_extensions(old, version, extwlist=False):
    extwlist = 3 if extwlist else 2
    ret = []

    def maybe_append(name):
        value = extensions.get(name)
        is_supported = value is None or (
            value[0] <= version <= value[1]
            and extension_is_installed(name, version)
            and value[extwlist]
        )
        if name not in ret and is_supported:
            ret.append(name)

    for name in old.split(','):
        maybe_append(name.strip())

    for name in extensions.keys():
        maybe_append(name)

    return ','.join(ret)


def extension_is_installed(name, version):
    control_name = extension_control_files.get(name, name)
    version_name = str(int(version)) if float(version).is_integer() else str(version)
    control_path = os.path.join(SHARE_DIR, version_name, 'extension', '{0}.control'.format(control_name))
    return os.path.isfile(control_path)


def get_binary_version(bin_dir):
    postgres = os.path.join(bin_dir or '', 'postgres')
    version = subprocess.check_output([postgres, '--version']).decode()
    version = re.match(r'^[^\s]+ [^\s]+ (\d+)(\.(\d+))?', version)
    return '.'.join([version.group(1), version.group(3)]) if int(version.group(1)) < 10 else version.group(1)


def get_bin_dir(version):
    return '{0}/{1}/bin'.format(LIB_DIR, version)


def is_valid_pg_version(version):
    bin_dir = get_bin_dir(version)
    postgres = os.path.join(bin_dir, 'postgres')
    # check that there is postgres binary inside
    return os.path.isfile(postgres) and os.access(postgres, os.X_OK)


def write_file(config, filename, overwrite):
    if not overwrite and os.path.exists(filename):
        logger.warning('File %s already exists, not overwriting. (Use option --force if necessary)', filename)
    else:
        with open(filename, 'w') as f:
            logger.info('Writing to file %s', filename)
            f.write(config)


def get_patroni_config():
    with open(PATRONI_CONFIG_FILE) as f:
        return yaml.safe_load(f)


def write_patroni_config(config, force):
    write_file(yaml.dump(config, default_flow_style=False, width=120), PATRONI_CONFIG_FILE, force)
