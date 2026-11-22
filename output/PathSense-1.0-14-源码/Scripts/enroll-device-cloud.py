#!/usr/bin/env python3
"""Seal the direct-cloud credential to one explicitly selected, paired physical iPhone Pro."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import stat
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent
BUNDLE = 'org.crosspointx.pathsense'
PUBLIC_KEY = 'Library/Caches/PathSense-EnrollmentPublic.bin'
SEALED = 'tmp/PathSense-CloudEnrollment.sealed'
UDID = re.compile(r'(?:[0-9a-f]{8}-[0-9a-f]{16}|[0-9a-f]{40})', re.IGNORECASE | re.ASCII)
CORE_ID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', re.IGNORECASE | re.ASCII)


class EnrollmentError(Exception):
    """Only fixed, non-sensitive stage messages reach the caller."""


def run(arguments, failure, *, plaintext=None):
    # The compiler, devicectl and sealer never inherit provider variables or shell configuration.
    child_env = {key: os.environ[key] for key in ('HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL') if key in os.environ}
    child_env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    options = {'stdin': subprocess.DEVNULL} if plaintext is None else {'input': plaintext}
    try:
        return subprocess.run(arguments, check=True, timeout=120, env=child_env, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, **options).stdout
    except (OSError, subprocess.SubprocessError):
        raise EnrollmentError(failure) from None


def target_udid(selected, device):
    properties = device.get('properties', {})
    hardware = properties.get('hardware') or device.get('hardwareProperties', {})
    connection = properties.get('connection') or device.get('connectionProperties', {})
    udid = hardware.get('udid', '')
    matches = any(isinstance(value, str) and value.casefold() == selected.casefold()
                  for value in (udid, device.get('identifier')))
    if (not matches or not isinstance(udid, str) or not UDID.fullmatch(udid)
            or connection.get('pairingState') != 'paired' or hardware.get('reality') != 'physical'
            or hardware.get('platform') != 'iOS' or hardware.get('deviceType') != 'iPhone'
            or not re.fullmatch(r'iPhone [1-9][0-9]* Pro', hardware.get('marketingName') or '', re.ASCII)):
        raise EnrollmentError('所选设备不是与此 Mac 配对的实体 iPhone Pro，或设备身份无法核验。')
    return udid


def resolve_device(selected):
    if not (UDID.fullmatch(selected) or CORE_ID.fullmatch(selected)):
        raise EnrollmentError('请给 --device 提供完整设备 UDID 或 CoreDevice UUID。')
    # Query only the requested device. Re-check its immutable ID and model before accessing its app container.
    raw = run(['/usr/bin/xcrun', 'devicectl', 'device', 'info', 'details', '--device', selected,
               '--timeout', '25', '--quiet', '--json-output', '-'], 'devicectl 无法读取所选设备的身份。')
    try:
        result = json.loads(raw)['result']
        return target_udid(selected, result.get('device', result))
    except (ValueError, TypeError, KeyError, AttributeError):
        raise EnrollmentError('devicectl 返回的设备身份无法核验。') from None


def copy_device_file(device, direction, source, destination, failure):
    run(['/usr/bin/xcrun', 'devicectl', 'device', 'copy', direction, '--quiet', '--timeout', '40',
         '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
         '--source', str(source), '--destination', str(destination)], failure)


def configured_credential():
    # Prefer a device-specific configuration when provided, then use the relay's normal environment/file lookup.
    # Never import or read the provider configuration on the --self-test path.
    sys.dont_write_bytecode = True
    project_server = SCRIPTS.parent / 'Proxy' / 'server.py'
    previous = os.environ.get('DEEPSEEK_API_KEY')
    dedicated = os.environ.get('PATHSENSE_DEVICE_DEEPSEEK_API_KEY')
    try:
        if dedicated is not None:
            if not dedicated.strip():
                raise ValueError('empty device credential')
            os.environ['DEEPSEEK_API_KEY'] = dedicated
        with open(os.devnull, 'w') as discard, contextlib.redirect_stdout(discard), contextlib.redirect_stderr(discard):
            spec = importlib.util.spec_from_file_location('pathsense_enrollment_proxy', project_server)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            secret = bytearray(module.demo_key(), 'ascii')
        if not 16 <= len(secret) <= 512 or not all(33 <= byte <= 126 for byte in secret):
            raise ValueError('invalid format')
        return secret
    except (Exception, SystemExit):
        raise EnrollmentError('项目未配置有效凭据。请检查设备专用环境配置或现有的代理配置。') from None
    finally:
        if dedicated is not None:
            if previous is None:
                os.environ.pop('DEEPSEEK_API_KEY', None)
            else:
                os.environ['DEEPSEEK_API_KEY'] = previous


def check_device_selection():
    # Synthetic identities only. The self-test does not invoke devicectl.
    udid = '00000000-0000000000000001'
    identifier = '11111111-0000-0000-0000-000000000001'
    base = dict(udid=udid, reality='physical', platform='iOS', deviceType='iPhone', marketingName='iPhone 17 Pro')
    def record(hardware, pairing='paired'):
        return {'identifier': identifier, 'properties': {'hardware': hardware, 'connection': {'pairingState': pairing}}}
    if target_udid(identifier, record(base)) != udid or target_udid(udid, record(base)) != udid:
        raise EnrollmentError('设备身份自检失败。')
    for selected, row in [(udid, record(dict(base, reality='simulated'))), (udid, record(dict(base, marketingName='iPhone Air'))),
                          (udid, record(base, 'unpaired')), ('00000000-0000000000000002', record(base))]:
        try:
            target_udid(selected, row)
        except EnrollmentError:
            continue
        raise EnrollmentError('设备身份自检失败。')


def enroll(device):
    # A normal run verifies the recipient before the only call which can load an actual credential.
    selected = resolve_device(device) if device is not None else None
    with tempfile.TemporaryDirectory(prefix='pathsense-seal-') as temp:
        working = Path(temp)
        helper = working / 'seal'
        run(['/usr/bin/xcrun', '--sdk', 'macosx', 'swiftc', '-module-cache-path', working / 'modules',
             SCRIPTS / 'seal-device-enrollment.swift', '-o', helper], 'Swift 加密工具未能编译。')
        run([helper, '--self-test'], '加密往返及完整性自检失败。')
        if selected is None:
            check_device_selection()
            return
        public = working / 'recipient.bin'
        copy_device_file(selected, 'from', PUBLIC_KEY, public, '无法取得应用公钥。请检查 iPhone 已解锁且已启动具备加密注册功能的 PathSense。')
        info = public.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size != 65:
            raise EnrollmentError('应用公钥格式无效。')
        run([helper, '--check-public-key', public], '应用公钥无法用于加密注册。')
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        secret = configured_credential()
        try:
            box = run([helper, '--seal', public], '加密失败。', plaintext=secret)
            if not len(secret) < len(box) <= 1024:
                raise EnrollmentError('加密结果大小无效。')
        finally:
            secret[:] = bytes(len(secret))
        sealed = working / 'enrollment.sealed'
        with os.fdopen(os.open(sealed, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as output:
            output.write(box)
        copy_device_file(selected, 'to', sealed, SEALED, '密文未送达设备。')


class Parser(argparse.ArgumentParser):
    def error(self, message):
        # Avoid echoing unrecognized arguments, which might contain a value pasted by mistake.
        self.exit(2, '请选择 --self-test 或 --device <UDID/CoreDevice UUID>。\n')


if __name__ == '__main__':
    parser = Parser(description=__doc__, allow_abbrev=False)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--self-test', action='store_true', help='只用临时软件密钥和模拟身份自检，不读取配置或连接设备。')
    mode.add_argument('--device', metavar='ID', help='已配对的实体 iPhone Pro 的完整 UDID 或 CoreDevice UUID。')
    options = parser.parse_args()
    try:
        enroll(options.device)
    except EnrollmentError as failure:
        sys.exit(str(failure))
    except (OSError, ValueError):
        sys.exit('注册未完成。请检查本机工具和临时文件是否可用。')
    print('加密往返、篡改拒绝和设备选择自检通过。' if options.self_test else '密文已交付到指定 iPhone Pro 的 PathSense 容器。启动应用以导入并进行云端自检。')
