'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require rpc';
'require tools.widgets as widgets';

var UCI_CONF = 'xrayclient';
var INIT_SCRIPT = '/etc/init.d/xrayclient';
var LOG_FILE = '/var/log/xrayclient.log';
var DATA_DIR = '/usr/share/xrayclient';
var ASSET_DIR = '/usr/share/v2ray';
var UPDATE_SCRIPT = '/usr/share/xrayclient/update_data.sh';

/* 数据文件路径 (geoip/geosite 由 v2ray-geoip/v2ray-geosite 包提供) */
var DATA_FILES = {
    cn_v4: DATA_DIR + '/cn_v4.list',
    cn_v6: DATA_DIR + '/cn_v6.list',
    geoip: ASSET_DIR + '/geoip.dat',
    geosite: ASSET_DIR + '/geosite.dat'
};

/* HTML 转义，防止日志内容中的特殊字符破坏页面 */
function escapeHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

/* 通过 ubus rpc 查询服务状态
 * service.list 返回结构:
 *   { xrayclient: { instances: { instance1: { running: true, pid: 123 } } } }
 * 服务未运行时返回: {} */
var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

return view.extend({
    load: function () {
        return Promise.all([
            callServiceList('xrayclient').then(function (info) {
                return !!(info && info.xrayclient && info.xrayclient.instances &&
                          info.xrayclient.instances.instance1 &&
                          info.xrayclient.instances.instance1.running);
            }).catch(function () { return false; }),
            uci.load(UCI_CONF),
            fs.read(LOG_FILE).catch(function () { return ''; }),
            /* 获取 4 个数据文件的修改时间 */
            Promise.all(Object.keys(DATA_FILES).map(function (key) {
                return fs.stat(DATA_FILES[key]).then(function (st) {
                    return { key: key, mtime: st.mtime };
                }).catch(function () {
                    return { key: key, mtime: null };
                });
            }))
        ]);
    },

    render: function (data) {
        var running = data[0];
        this.running = running;
        var logContent = data[2] || '';
        var fileStats = data[3] || [];
        var nodes = uci.sections(UCI_CONF, 'node');

        /* 将文件 mtime 转为可读时间 */
        var fileMtimeMap = {};
        fileStats.forEach(function (item) {
            fileMtimeMap[item.key] = item.mtime;
        });
        function formatTime(ts) {
            if (!ts) return _('未下载');
            var d = new Date(ts * 1000);
            return d.toLocaleString();
        }

        var m = new form.Map(UCI_CONF, _('Xray Client'), _('Xray客户端管理界面'));
        m.tabbed = true;

        /* ====== 概览 ====== */
        var sOverview = m.section(form.NamedSection, 'main', _('概览'));

        /* 判断活动节点是否有效 (active_node 非空 && 对应 node 存在) */
        var activeNodeName = uci.get(UCI_CONF, 'main', 'active_node') || '';
        var activeNodeValid = false;
        if (activeNodeName) {
            var activeNodeSection = uci.get(UCI_CONF, activeNodeName);
            activeNodeValid = !!(activeNodeSection && activeNodeSection.protocol);
        }

        var oStat = sOverview.option(form.DummyValue, '_status', _('运行状态'));
        oStat.renderWidget = function () {
            /* 判断状态: 运行中 / 已停止 / 启动失败 */
            var statusText, statusColor;
            var showCleanupBtn = false;
            if (running) {
                statusText = _('运行中');
                statusColor = '#46b450';
            } else if (activeNodeValid) {
                /* 节点已选中且存在，但服务未运行 → 启动失败 */
                statusText = _('启动失败');
                statusColor = '#dc3232';
                showCleanupBtn = true;
            } else {
                statusText = _('已停止');
                statusColor = '#dc3232';
            }

            var elements = [E('span', {
                style: 'font-weight:bold;color:' + statusColor
            }, '\u25CF ' + statusText)];

            if (showCleanupBtn) {
                elements.push(E('button', {
                    'type': 'button',
                    'class': 'cbi-button cbi-button-neutral',
                    'style': 'margin-left:10px;',
                    'click': function (ev) {
                        ui.showModal(_('清理路由规则'), [
                            E('p', { 'class': 'spinning' }, _('正在清理 nftables 和路由规则...'))
                        ]);
                        Promise.all([
                            fs.exec('/usr/share/xrayclient/remove_nft.sh').catch(function () {}),
                            fs.exec('/usr/share/xrayclient/remove_route.sh').catch(function () {})
                        ]).then(function () {
                            ui.hideModal();
                            ui.addNotification(null, E('p', _('路由及 nftables 规则已清理。')));
                            window.setTimeout(function () { window.location.reload(); }, 2000);
                        });
                    }
                }, _('清除路由规则')));
            }

            return E('div', { style: 'display:flex;align-items:center;gap:8px;' }, elements);
        };

        var oActive = sOverview.option(form.ListValue, 'active_node', _('当前代理节点'));
        oActive.value('', _('停用'));
        nodes.forEach(function (s) {
            var label = s.alias || ((s.address || _('未设置')) + ':' + (s.port || ''));
            oActive.value(s['.name'], label);
        });
        oActive.description = _('选择当前使用的代理节点。选择"停用"将停止代理服务；选择节点则通过该节点转发流量。');

        /* --- 国内域名 DNS 摘要 --- */
        var oLocalDnsSum = sOverview.option(form.DummyValue, '_local_dns_summary', _('国内域名 DNS'));
        oLocalDnsSum.rawhtml = true;
        oLocalDnsSum.cfgvalue = function () {
            var srv = uci.get(UCI_CONF, 'main', 'local_dns_server') || '223.5.5.5';
            var port = uci.get(UCI_CONF, 'main', 'local_dns_port') || '53';
            var html = '<span style="font-weight:bold">' + srv + ':' + port + '</span>';
            /* 检测是否为内网地址 */
            var isLan = false;
            if (/^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/.test(srv) ||
                srv === 'localhost' || srv === '::1') {
                isLan = true;
            }
            if (isLan) {
                html += '<div style="margin-top:4px;font-size:12px;color:#b35900;">\u26A0 DNS 在本地局域网，请确认其查询流量不经代理，否则将导致循环。</div>';
            }
            return html;
        };

        /* --- FakeIP 摘要 --- */
        var oFakeipSum = sOverview.option(form.DummyValue, '_fakeip_summary', _('FakeIP 网段'));
        oFakeipSum.cfgvalue = function () {
            return uci.get(UCI_CONF, 'main', 'fakeip_cidr') || '198.18.0.0/15';
        };

        /* --- 未知域名 DNS 摘要 --- */
        var remoteDnsList = uci.sections(UCI_CONF, 'remote_dns');
        var remoteDnsSummary = remoteDnsList.length > 0
            ? remoteDnsList.map(function (s) { return (s.address || '?') + ':' + (s.port || '53'); }).join('、')
            : _('未配置');

        var oRDnsSum = sOverview.option(form.DummyValue, '_remote_dns_summary', _('未知域名 DNS'));
        oRDnsSum.renderWidget = function () {
            return E('span', { style: 'font-weight:bold' }, remoteDnsSummary);
        };

        /* --- 数据文件状态 --- */
        var oDataStatus = sOverview.option(form.DummyValue, '_data_status', _('数据文件状态'));
        oDataStatus.rawhtml = true;
        oDataStatus.cfgvalue = function () {
            var rows = [
                { label: 'cn_v4.list', time: formatTime(fileMtimeMap.cn_v4) },
                { label: 'cn_v6.list', time: formatTime(fileMtimeMap.cn_v6) },
                { label: 'geoip.dat', time: formatTime(fileMtimeMap.geoip) },
                { label: 'geosite.dat', time: formatTime(fileMtimeMap.geosite) }
            ];
            var html = '<div style="margin:6px 0;">';
            rows.forEach(function (r) {
                var color = r.time === _('未下载') ? '#dc3232' : '#46b450';
                html += '<div style="display:flex;align-items:center;padding:4px 0;border-bottom:1px solid #eee;">' +
                    '<span style="min-width:140px;font-weight:600;">' + r.label + '</span>' +
                    '<span style="color:' + color + ';">' + r.time + '</span>' +
                    '</div>';
            });
            html += '</div>';
            html += '<div style="display:flex;gap:8px;align-items:center;">';
            html += '<button type="button" class="cbi-button cbi-button-action" id="xrayclient-update-btn-overview">' + _('立即更新') + '</button>';
            html += '<button type="button" class="cbi-button cbi-button-neutral" id="xrayclient-goto-update-config">' + _('更新配置') + '</button>';
            html += '</div>';
            return html;
        };

        /* ====== 节点列表 ====== */
        var sNodes = m.section(form.GridSection, 'node', _('节点列表'));
        sNodes.addremove = true;
        sNodes.nodescriptions = true;
        sNodes.anonymous = true;
        sNodes.addbtntitle = _('+ 添加节点');
        sNodes.modaltitle = function (section_id) {
            var alias = uci.get(UCI_CONF, section_id, 'alias');
            return _('节点详情') + ' \u2014 ' + (alias || section_id);
        };

        /* 表格列: 别名 + 服务器地址 + 端口 */
		var dummyProto = sNodes.option(form.DummyValue, 'protocol', _('协议'));
		dummyProto.modalonly = false;
        sNodes.option(form.Value, 'alias', _('别名'));
        sNodes.option(form.Value, 'address', _('服务器地址')).datatype = 'host';
        sNodes.option(form.Value, 'port', _('端口')).datatype = 'port';

        /* ====== 模态框字段 ====== */

        /* --- 协议选择 --- */
        var oProto = sNodes.option(form.ListValue, 'protocol', _('协议'));
        oProto.modalonly = true;
        oProto.value('', _('-- 请选择 --'));
        oProto.value('vless', 'VLESS');
        oProto.value('shadowsocks', 'Shadowsocks');
        oProto.value('vmess', 'VMess');
        oProto.description = _('选择代理协议类型。');

        /* --- 基本信息（依赖协议 = vless）--- */
        var oId = sNodes.option(form.Value, 'id', _('用户 ID (UUID)'));
        oId.modalonly = true;
        oId.depends('protocol', 'vless');

        var oEnc = sNodes.option(form.Value, 'encryption', _('VLESS 加密 (encryption)'));
        oEnc.modalonly = true;
        oEnc.depends('protocol', 'vless');
        oEnc.placeholder = 'none';
        oEnc.description = _('默认 none。如需 VLESS 加密，可填入加密串（如 mlkem768x25519plus...）。');

        var oFlow = sNodes.option(form.ListValue, 'flow', _('Flow (流控)'));
        oFlow.modalonly = true;
        oFlow.depends('protocol', 'vless');
        oFlow.value('', _('不使用'));
        oFlow.value('xtls-rprx-vision', 'xtls-rprx-vision');
        oFlow.value('xtls-rprx-vision-udp443', 'xtls-rprx-vision-udp443');
        oFlow.description = _('XTLS 流控方式。推荐使用 xtls-rprx-vision，可获得真实 IP 透传与最佳性能。');

        var oLvl = sNodes.option(form.Value, 'level', _('用户等级'));
        oLvl.modalonly = true;
        oLvl.depends('protocol', 'vless');
        oLvl.datatype = 'uinteger';
        oLvl.placeholder = '0';

        /* --- 传输协议（通用，所有协议共享）--- */
        var oNet = sNodes.option(form.ListValue, 'network', _('传输协议 (network)'));
        oNet.modalonly = true;
        oNet.value('raw', 'raw');
        oNet.value('tcp', 'tcp (兼容旧名)');
        oNet.value('ws', 'websocket');
        oNet.value('grpc', 'grpc');
        oNet.value('mkcp', 'mkcp');
        oNet.value('httpupgrade', 'httpupgrade');
        oNet.value('xhttp', 'xhttp');
        oNet.description = _('选择底层传输协议，默认为 raw (TCP)。');

        /* --- WebSocket 传输设置 --- */
        var oWsPath = sNodes.option(form.Value, 'ws_path', _('WS 路径 (path)'));
        oWsPath.modalonly = true;
        oWsPath.depends('network', 'ws');
        oWsPath.placeholder = '/';

        var oWsHost = sNodes.option(form.Value, 'ws_host', _('WS Host'));
        oWsHost.modalonly = true;
        oWsHost.depends('network', 'ws');

        /* --- gRPC 传输设置 --- */
        var oGrpcSvc = sNodes.option(form.Value, 'grpc_serviceName', _('gRPC ServiceName'));
        oGrpcSvc.modalonly = true;
        oGrpcSvc.depends('network', 'grpc');

        var oGrpcAuth = sNodes.option(form.Value, 'grpc_authority', _('gRPC Authority'));
        oGrpcAuth.modalonly = true;
        oGrpcAuth.depends('network', 'grpc');

        var oGrpcMulti = sNodes.option(form.Flag, 'grpc_multiMode', _('gRPC MultiMode'));
        oGrpcMulti.modalonly = true;
        oGrpcMulti.depends('network', 'grpc');
        oGrpcMulti.description = _('实验性选项，约 20% 性能提升，不保证跨版本兼容。');

        /* --- mKCP 传输设置 --- */
        var oKcpMtu = sNodes.option(form.Value, 'kcp_mtu', _('mKCP MTU'));
        oKcpMtu.modalonly = true;
        oKcpMtu.depends('network', 'mkcp');
        oKcpMtu.datatype = 'range(576,1460)';
        oKcpMtu.placeholder = '1350';

        var oKcpTti = sNodes.option(form.Value, 'kcp_tti', _('mKCP TTI (ms)'));
        oKcpTti.modalonly = true;
        oKcpTti.depends('network', 'mkcp');
        oKcpTti.datatype = 'range(10,100)';
        oKcpTti.placeholder = '50';

        var oKcpUp = sNodes.option(form.Value, 'kcp_uplinkCapacity', _('mKCP 上行带宽 (MB/s)'));
        oKcpUp.modalonly = true;
        oKcpUp.depends('network', 'mkcp');
        oKcpUp.datatype = 'uinteger';
        oKcpUp.placeholder = '5';

        var oKcpDown = sNodes.option(form.Value, 'kcp_downlinkCapacity', _('mKCP 下行带宽 (MB/s)'));
        oKcpDown.modalonly = true;
        oKcpDown.depends('network', 'mkcp');
        oKcpDown.datatype = 'uinteger';
        oKcpDown.placeholder = '20';

        var oKcpCong = sNodes.option(form.Flag, 'kcp_congestion', _('mKCP 拥塞控制'));
        oKcpCong.modalonly = true;
        oKcpCong.depends('network', 'mkcp');

        /* --- HTTPUpgrade 传输设置 --- */
        var oHuPath = sNodes.option(form.Value, 'hu_path', _('HTTPUpgrade 路径 (path)'));
        oHuPath.modalonly = true;
        oHuPath.depends('network', 'httpupgrade');
        oHuPath.placeholder = '/';

        var oHuHost = sNodes.option(form.Value, 'hu_host', _('HTTPUpgrade Host'));
        oHuHost.modalonly = true;
        oHuHost.depends('network', 'httpupgrade');

        /* --- XHTTP 传输设置 --- */
        var oXhPath = sNodes.option(form.Value, 'xh_path', _('XHTTP 路径 (path)'));
        oXhPath.modalonly = true;
        oXhPath.depends('network', 'xhttp');

        var oXhHost = sNodes.option(form.Value, 'xh_host', _('XHTTP Host'));
        oXhHost.modalonly = true;
        oXhHost.depends('network', 'xhttp');

        var oXhMode = sNodes.option(form.ListValue, 'xh_mode', _('XHTTP Mode'));
        oXhMode.modalonly = true;
        oXhMode.depends('network', 'xhttp');
        oXhMode.value('', _('默认'));
        oXhMode.value('auto', 'auto');
        oXhMode.value('packet-up', 'packet-up');
        oXhMode.value('stream-up', 'stream-up');
        oXhMode.value('stream-one', 'stream-one');

        /* --- 安全协议（通用，所有协议共享）--- */
        var oSec = sNodes.option(form.ListValue, 'security', _('安全 (security)'));
        oSec.modalonly = true;
        oSec.value('none', 'none');
        oSec.value('tls', 'tls');
        oSec.value('reality', 'reality');
        oSec.description = _('选择传输层安全协议。REALITY 为推荐选项，具有更强的抗检测能力。');

        /* --- REALITY + TLS 共有字段 --- */
        var oSN = sNodes.option(form.Value, 'serverName', _('ServerName (SNI)'));
        oSN.modalonly = true;
        oSN.depends('security', 'reality');
        oSN.depends('security', 'tls');
        oSN.description = _('TLS/REALITY 握手使用的服务器名称。');

        var oFP = sNodes.option(form.ListValue, 'fingerprint', _('TLS 指纹 (Fingerprint)'));
        oFP.modalonly = true;
        oFP.value('', _('不使用'));
        oFP.value('chrome', 'chrome');
        oFP.value('firefox', 'firefox');
        oFP.value('safari', 'safari');
        oFP.value('ios', 'ios');
        oFP.value('android', 'android');
        oFP.value('edge', 'edge');
        oFP.value('360', '360');
        oFP.value('qq', 'qq');
        oFP.value('random', 'random');
        oFP.value('randomized', 'randomized');
        oFP.depends('security', 'reality');
        oFP.depends('security', 'tls');
        oFP.description = _('模拟浏览器 TLS 指纹，用于规避流量检测。');

        /* --- REALITY 专属字段 --- */
        var oPwd = sNodes.option(form.Value, 'password', _('Password (REALITY 公钥)'));
        oPwd.modalonly = true;
        oPwd.depends('security', 'reality');
        oPwd.description = _('REALITY 协议密码，通常为服务端配置的公钥。');

        var oSID = sNodes.option(form.Value, 'shortId', _('Short ID'));
        oSID.modalonly = true;
        oSID.depends('security', 'reality');
        oSID.description = _('REALITY 短 ID，需与服务端配置一致。');

        var oMLD = sNodes.option(form.Value, 'mldsa65Verify', _('mldsa65Verify'));
        oMLD.modalonly = true;
        oMLD.depends('security', 'reality');
        oMLD.description = _('后量子签名验证，通常留空即可。');

        var oSPX = sNodes.option(form.Value, 'spiderX', _('SpiderX'));
        oSPX.modalonly = true;
        oSPX.depends('security', 'reality');
        oSPX.description = _('REALITY SpiderX 路径，通常留空即可。');

        /* --- 基本信息（依赖协议 = shadowsocks）--- */
        var oSsMethod = sNodes.option(form.ListValue, 'method', _('加密方式 (method)'));
        oSsMethod.modalonly = true;
        oSsMethod.depends('protocol', 'shadowsocks');
        oSsMethod.value('2022-blake3-aes-128-gcm', '2022-blake3-aes-128-gcm');
        oSsMethod.value('2022-blake3-aes-256-gcm', '2022-blake3-aes-256-gcm');
        oSsMethod.value('2022-blake3-chacha20-poly1305', '2022-blake3-chacha20-poly1305');
        oSsMethod.value('aes-256-gcm', 'aes-256-gcm');
        oSsMethod.value('aes-128-gcm', 'aes-128-gcm');
        oSsMethod.value('chacha20-poly1305', 'chacha20-poly1305');
        oSsMethod.value('xchacha20-poly1305', 'xchacha20-poly1305');
        oSsMethod.value('none', 'none');

        var oSsPwd = sNodes.option(form.Value, 'ss_password', _('密码 (password)'));
        oSsPwd.modalonly = true;
        oSsPwd.depends('protocol', 'shadowsocks');
        oSsPwd.password = true;

        var oSsLvl = sNodes.option(form.Value, 'level', _('用户等级 (level)'));
        oSsLvl.modalonly = true;
        oSsLvl.depends('protocol', 'shadowsocks');
        oSsLvl.datatype = 'uinteger';
        oSsLvl.placeholder = '0';

        /* --- 基本信息（依赖协议 = vmess）--- */
        var oVmId = sNodes.option(form.Value, 'id', _('用户 ID (UUID)'));
        oVmId.modalonly = true;
        oVmId.depends('protocol', 'vmess');

        var oVmSec = sNodes.option(form.ListValue, 'vmess_security', _('VMess 加密 (security)'));
        oVmSec.modalonly = true;
        oVmSec.depends('protocol', 'vmess');
        oVmSec.value('auto', 'auto (默认)');
        oVmSec.value('aes-128-gcm', 'aes-128-gcm');
        oVmSec.value('chacha20-poly1305', 'chacha20-poly1305');
        oVmSec.value('none', 'none');
        oVmSec.value('zero', 'zero');

        var oVmExp = sNodes.option(form.Value, 'experiments', _('实验性功能 (experiments)'));
        oVmExp.modalonly = true;
        oVmExp.depends('protocol', 'vmess');
        oVmExp.description = _('可选值: AuthenticatedLength。NoTerminationSignal 已默认启用无需填写。');

        var oVmLvl = sNodes.option(form.Value, 'level', _('用户等级 (level)'));
        oVmLvl.modalonly = true;
        oVmLvl.depends('protocol', 'vmess');
        oVmLvl.datatype = 'uinteger';
        oVmLvl.placeholder = '0';

        /* --- TLS 专属字段 --- */
        var oAI = sNodes.option(form.Flag, 'allow_insecure', _('允许不安全连接'));
        oAI.modalonly = true;
        oAI.depends('security', 'tls');
        oAI.description = _('允许不安全的 TLS 连接（跳过证书验证）。出于安全性考虑不建议启用，仅在服务端使用自签名证书时开启。');

        /* --- 底层网络设置（通用）--- */
        var oTcpCong = sNodes.option(form.ListValue, 'tcpcongestion', _('TCP 拥塞控制算法'));
        oTcpCong.modalonly = true;
        oTcpCong.value('', _('系统默认'));
        oTcpCong.value('bbr', 'bbr');
        oTcpCong.value('cubic', 'cubic');
        oTcpCong.value('reno', 'reno');
        oTcpCong.description = _('底层 TCP 拥塞控制算法，通常保持系统默认即可。');

        /* ====== 国内域名DNS ====== */
        var sDns = m.section(form.NamedSection, 'main', _('国内域名DNS'));

        /* --- 自定义国内域名 DNS --- */
        var oCustomDns = sDns.option(form.Flag, 'custom_local_dns', _('自定义国内域名 DNS'));
        oCustomDns.description = _('勾选后手动指定国内域名 DNS 地址；不勾选则每次启动时自动从系统上游 DNS 检测。');

        /* --- 国内域名 DNS --- */
        var oLds = sDns.option(form.Value, 'local_dns_server', _('国内域名 DNS 地址'));
        oLds.datatype = 'host';
        oLds.placeholder = _('用于解析国内域名');
        oLds.depends('custom_local_dns', '1');
        oLds.retain = true;

        var oLdp = sDns.option(form.Value, 'local_dns_port', _('国内域名 DNS 端口'));
        oLdp.datatype = 'port';
        oLdp.placeholder = '53';
        oLdp.depends('custom_local_dns', '1');
        oLdp.retain = true;

        /* 国内 DNS 警告 */
        var oWarn = sDns.option(form.DummyValue, '_local_dns_warn', _(' '));
        oWarn.depends('custom_local_dns', '1');
        oWarn.renderWidget = function () {
            return E('div', {
                style: 'padding:10px 14px;margin:6px 0;border:1px solid #ffb900;background:#fff8e5;border-radius:4px;font-size:13px;line-height:1.6;'
            }, [
                E('strong', { style: 'color:#b35900' }, '\u26A0 ' + _('重要提示')),
                E('br'),
                _('用于解析国内域名的 DNS 服务器其流量不可经由本代理转发，否则将导致 DNS 查询陷入无限循环。'),
                E('br'),
                _('切勿将网关指向本代理软件所在路由器的 DNS 配置为本项。')
            ]);
        };

        /* --- 尝试使用国内 DNS 解析的域名 --- */
        var oCnDnsDomains = sDns.option(form.DynamicList, 'cn_dns_domains', _('尝试使用国内 DNS 解析的域名'));
        oCnDnsDomains.description = _('除默认已包含的 geosite:cn、geosite:apple、geosite:microsoft 外，可在此添加额外域名。这些域名将优先使用国内 DNS 解析；若解析结果非国内 IP，则回退至 FakeIP 机制交由代理处理。');

        /* ====== FakeIP ====== */
        var sFakeip = m.section(form.NamedSection, 'main', _('FakeIP'));

        var oFip = sFakeip.option(form.Value, 'fakeip_cidr', _('FakeIP 网段'));
        oFip.placeholder = '198.18.0.0/15';

        var oFakeipDomains = sFakeip.option(form.DynamicList, 'fakeip_domains', _('使用 FakeIP 的域名'));
        oFakeipDomains.description = _('除默认已包含的 geosite:google 外，可在此添加额外域名。这些域名将跳过 DNS 查询直接返回 FakeIP 地址，由代理服务器在远端完成真实解析。');

        var oFipNote = sFakeip.option(form.DummyValue, '_fip_note', _(' '));
        oFipNote.renderWidget = function () {
            return E('div', {
                style: 'padding:10px 14px;margin:6px 0;border:1px solid #6f42c1;background:#f5f0ff;border-radius:4px;font-size:13px;line-height:1.6;'
            }, [
                E('strong', { style: 'color:#563d7c' }, 'ⓘ ' + _('FakeIP 机制说明')),
                E('br'),
                _('已知的国外域名将跳过 DNS 查询，直接快速返回 FakeIP 地址。'),
                E('br'),
                _('当客户端使用该 FakeIP 发起连接时，流量将直接交由代理服务器处理，由代理服务器在远端完成真实域名解析。'),
                E('br'),
                _('此机制可显著降低首次连接延迟并避免 DNS 污染。')
            ]);
        };

        /* ====== 未知域名DNS ====== */
        var sRDns = m.section(form.GridSection, 'remote_dns', _('未知域名DNS'));
        sRDns.addremove = true;
        sRDns.nodescriptions = true;
        sRDns.addbtntitle = _('+ 添加 DNS');
        sRDns.modaltitle = function (section_id) {
            return _('DNS 服务器详情') + ' \u2014 ' + section_id;
        };
        sRDns.description = '<div style="padding:10px 14px;margin:6px 0;border:1px solid #6f42c1;background:#f5f0ff;border-radius:4px;font-size:13px;line-height:1.6;">' +
            '<strong style="color:#563d7c;">ⓘ ' + _('未知域名DNS 说明') + '</strong><br>' +
            _('未知域名指不在国内域名集中且不在尝试使用国内 DNS 解析的域名集中的域名。') + '<br>' +
            _('支持配置多个用于解析未知域名的 DNS 服务器，xray将通过代理对所有下面已配置的服务器同时发起查询，任一服务器返回有效结果即生效。此机制可提升解析可靠性并降低延迟。') + '<br>' +
            _('注意！如果解析出的ip结果在国内ip集中，那最终仍然会使用国内dns再次查询。') +
            '</div>';
        sRDns.renderSectionAdd = function (extra_class) {
            var el = form.GridSection.prototype.renderSectionAdd.apply(this, [extra_class]);
            var input = el.querySelector('input[type="text"]');
            if (input) {
                input.placeholder = _('DNS 名称');
            }
            return el;
        };

        /* 表格列 */
        sRDns.option(form.Value, 'address', _('DNS 服务器地址')).datatype = 'host';
        sRDns.option(form.Value, 'port', _('端口')).datatype = 'port';

        /* ====== 访问控制 ====== */
        var sAccess = m.section(form.NamedSection, 'main', _('访问控制'));

        /* --- 监控接口 --- */
        var oIface = sAccess.option(widgets.NetworkSelect, 'nft_lan_iface', _('监控接口'));
        oIface.description = _('仅监控来自此接口的流量，非此接口的流量直接放行。默认使用 lan 接口。');
        oIface.multiple = true;

        var oBld = sAccess.option(form.DynamicList, 'blacklist_domain', _('黑名单域名'));
        oBld.description = _('匹配到的域名将强制经由代理转发。支持 geosite:、domain:、full: 等语法，详见 Xray 官方文档。');

        var oBli = sAccess.option(form.DynamicList, 'blacklist_ip', _('黑名单 IP'));
        oBli.description = _('匹配到的 IP 地址将强制经由代理转发。每行一条规则，支持 IPv4/IPv6 地址或 CIDR 段。');

        var oWld = sAccess.option(form.DynamicList, 'whitelist_domain', _('白名单域名'));
        oWld.description = _('匹配到的域名将直连，不经过代理。支持 geosite:、domain:、full: 等语法，详见 Xray 官方文档。');

        var oWlv4 = sAccess.option(form.DynamicList, 'nft_whitelist_v4', _('白名单 IPv4'));
        oWlv4.description = _('匹配到的 IPv4 地址将直连，不经过代理。支持单 IP 或 CIDR 段格式。');

        var oWlv6 = sAccess.option(form.DynamicList, 'nft_whitelist_v6', _('白名单 IPv6'));
        oWlv6.description = _('匹配到的 IPv6 地址将直连，不经过代理。支持单 IP 或 CIDR 段格式。');

        /* ====== 广告屏蔽 ====== */
        var sAdBlock = m.section(form.NamedSection, 'main', _('广告屏蔽'));
        sAdBlock.description = '<div style="font-size:14px;font-weight:600;color:#555;margin-bottom:24px;">' + _('启用后，列表中的广告域名将被解析至无效地址，从而实现屏蔽效果。') + '</div>';

        var oBlockAd = sAdBlock.option(form.Flag, 'block_ad', _('启用广告屏蔽'));
        oBlockAd.description = _('勾选后启用广告屏蔽功能。');

        var oBd = sAdBlock.option(form.DynamicList, 'block_domain', _('屏蔽域名列表'));
        oBd.description = _('支持 geosite:、domain:、full: 等语法，详见 Xray 官方文档。默认使用 geosite:category-ads-all 覆盖主流广告域名，可自行添加需要屏蔽的域名。');
        oBd.depends('block_ad', '1');

        /* ====== 更新配置 ====== */
        var sUpdate = m.section(form.NamedSection, 'main', _('更新配置'));

        /* --- IP 类数据更新配置 (cn_v4 + cn_v6 + geoip) --- */
        var oIpNote = sUpdate.option(form.DummyValue, '_ip_note', _(' '));
        oIpNote.rawhtml = true;
        oIpNote.cfgvalue = function () {
            return '<div style="font-size:14px;font-weight:600;color:#555;margin:12px 0 6px;">' + _('IP 类数据 (cn_v4 + cn_v6 + geoip)') + '</div>';
        };

        var oIpInterval = sUpdate.option(form.ListValue, 'ip_update_interval', _('更新频率'));
        oIpInterval.value('daily', _('每天'));
        oIpInterval.value('every3d', _('每 3 天'));
        oIpInterval.value('weekly', _('每周'));
        oIpInterval.value('never', _('不自动更新'));
        oIpInterval.default = 'weekly';

        var oIpHour = sUpdate.option(form.ListValue, 'ip_update_hour', _('更新时间'));
        oIpHour.depends('ip_update_interval', 'daily');
        oIpHour.depends('ip_update_interval', 'every3d');
        oIpHour.depends('ip_update_interval', 'weekly');
        for (var h1 = 0; h1 < 24; h1++) {
            oIpHour.value(String(h1), String(h1) + ':00');
        }
        oIpHour.default = '4';

        var oIpDow = sUpdate.option(form.ListValue, 'ip_update_dow', _('星期'));
        oIpDow.depends('ip_update_interval', 'weekly');
        oIpDow.value('0', _('周日'));
        oIpDow.value('1', _('周一'));
        oIpDow.value('2', _('周二'));
        oIpDow.value('3', _('周三'));
        oIpDow.value('4', _('周四'));
        oIpDow.value('5', _('周五'));
        oIpDow.value('6', _('周六'));
        oIpDow.default = '5';

        var oCnIpUrl = sUpdate.option(form.Value, 'cn_ip_url', _('中国 IPv4 列表 URL'));
        oCnIpUrl.placeholder = 'https://gaoyifan.github.io/china-operator-ip/china.txt';

        var oCnV6Url = sUpdate.option(form.Value, 'cn_v6_url', _('中国 IPv6 列表 URL'));
        oCnV6Url.placeholder = 'https://gaoyifan.github.io/china-operator-ip/china6.txt';

        var oGeoipUrl = sUpdate.option(form.Value, 'geoip_url', _('geoip.dat URL'));
        oGeoipUrl.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat';

        var oGeoipShaUrl = sUpdate.option(form.Value, 'geoip_sha256_url', _('geoip.dat 校验文件 URL'));
        oGeoipShaUrl.description = _('更新前先下载校验文件，与本地比对一致则跳过更新。留空则不校验，直接更新。');
        oGeoipShaUrl.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat.sha256sum';

        /* --- 域名类数据更新配置 (geosite) --- */
        var oDatNote = sUpdate.option(form.DummyValue, '_dat_note', _(' '));
        oDatNote.rawhtml = true;
        oDatNote.cfgvalue = function () {
            return '<div style="font-size:14px;font-weight:600;color:#555;margin:12px 0 6px;">' + _('域名类数据 (geosite)') + '</div>';
        };

        var oDatInterval = sUpdate.option(form.ListValue, 'dat_update_interval', _('更新频率'));
        oDatInterval.value('daily', _('每天'));
        oDatInterval.value('every3d', _('每 3 天'));
        oDatInterval.value('weekly', _('每周'));
        oDatInterval.value('never', _('不自动更新'));
        oDatInterval.default = 'every3d';

        var oDatHour = sUpdate.option(form.ListValue, 'dat_update_hour', _('更新时间'));
        oDatHour.depends('dat_update_interval', 'daily');
        oDatHour.depends('dat_update_interval', 'every3d');
        oDatHour.depends('dat_update_interval', 'weekly');
        for (var h2 = 0; h2 < 24; h2++) {
            oDatHour.value(String(h2), String(h2) + ':00');
        }
        oDatHour.default = '4';

        var oDatDow = sUpdate.option(form.ListValue, 'dat_update_dow', _('星期'));
        oDatDow.depends('dat_update_interval', 'weekly');
        oDatDow.value('0', _('周日'));
        oDatDow.value('1', _('周一'));
        oDatDow.value('2', _('周二'));
        oDatDow.value('3', _('周三'));
        oDatDow.value('4', _('周四'));
        oDatDow.value('5', _('周五'));
        oDatDow.value('6', _('周六'));
        oDatDow.default = '1';

        var oGeositeUrl = sUpdate.option(form.Value, 'geosite_url', _('geosite.dat URL'));
        oGeositeUrl.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat';

        var oGeositeShaUrl = sUpdate.option(form.Value, 'geosite_sha256_url', _('geosite.dat 校验文件 URL'));
        oGeositeShaUrl.description = _('更新前先下载校验文件，与本地比对一致则跳过更新。留空则不校验，直接更新。');
        oGeositeShaUrl.placeholder = 'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat.sha256sum';

        /* ====== 错误排查 ====== */
        var sLog = m.section(form.NamedSection, 'main', _('错误排查'));

        /* 日志说明（作为第一个 DummyValue，与日志框左对齐） */
        var oLogDesc = sLog.option(form.DummyValue, '_log_desc', _(' '));
        oLogDesc.rawhtml = true;
        oLogDesc.cfgvalue = function () {
            return '<div style="font-size:14px;font-weight:600;color:#555;">' + _('查看 Xray 客户端运行日志，用于排查连接异常或服务启动失败等问题。') + '</div>';
        };

        var oLog = sLog.option(form.DummyValue, '_log', _('日志内容'));
        oLog.cfgvalue = function () {
            return logContent || _('暂无日志');
        };
        oLog.renderWidget = function (section_id, option_index, cfgvalue) {
            var pre = E('pre', {
                id: 'xray-log-pre',
                style: 'width:100%;max-height:450px;overflow:auto;background:#1a1a2e;color:#e0e0e0;padding:12px;font-family:monospace;font-size:12px;white-space:pre-wrap;border-radius:4px;'
            }, escapeHtml(cfgvalue || _('暂无日志')));
            /* 渲染后滚动到底部，显示最新日志 */
            window.setTimeout(function () {
                pre.scrollTop = pre.scrollHeight;
            }, 0);
            return pre;
        };

        var oRefreshLog = sLog.option(form.Button, '_refresh_log', _(' '));
        oRefreshLog.inputtitle = _('刷新日志');
        oRefreshLog.inputstyle = 'action';
        oRefreshLog.onclick = function () {
            var pre = document.getElementById('xray-log-pre');
            if (!pre) return Promise.resolve();
            pre.textContent = _('加载中...');
            return fs.read(LOG_FILE).catch(function () { return ''; }).then(function (content) {
                pre.textContent = content || _('暂无日志');
                pre.scrollTop = pre.scrollHeight;
            });
        };

        var oClearLog = sLog.option(form.Button, '_clear_log', _(' '));
        oClearLog.inputtitle = _('清空日志');
        oClearLog.inputstyle = 'negative';
        oClearLog.onclick = function () {
            return fs.write(LOG_FILE, '').then(function () {
                var pre = document.getElementById('xray-log-pre');
                if (pre) {
                    pre.textContent = _('暂无日志');
                }
            });
        };

        /* --- 高级参数提示 --- */
        var oAdvNote = sLog.option(form.DummyValue, '_adv_note', _(' '));
        oAdvNote.rawhtml = true;
        oAdvNote.cfgvalue = function () {
            return '<div style="padding:10px 14px;margin:6px 0;border:1px solid #ffb900;background:#fff8e5;border-radius:4px;font-size:13px;line-height:1.6;">' +
                '<strong style="color:#b35900;">\u26A0 ' + _('排错参数') + '</strong><br>' +
                _('以下为系统内部配置参数，通常无需修改。仅当服务启动失败或网络异常时，可根据日志中的错误提示调整对应参数。') +
                '</div>';
        };

        /* --- 排错参数 --- */
        var oTP = sLog.option(form.Value, 'tproxy_port', _('TPROXY 端口'));
        oTP.datatype = 'port';
        oTP.description = _('Xray TPROXY 监听端口。');

        var oFwmark = sLog.option(form.Value, 'fwmark', _('防火墙标记 (fwmark)'));
        oFwmark.description = _('用于标记需要代理的流量，需确保不与系统中其他标记冲突。');

        var oV4Id = sLog.option(form.Value, 'table_v4_id', _('IPv4 路由表 ID'));
        var oV4Name = sLog.option(form.Value, 'table_v4_name', _('IPv4 路由表名称'));
        var oV6Id = sLog.option(form.Value, 'table_v6_id', _('IPv6 路由表 ID'));
        var oV6Name = sLog.option(form.Value, 'table_v6_name', _('IPv6 路由表名称'));

        var oNftTable = sLog.option(form.Value, 'nft_table_name', _('nftables 表名'));

        var oUsrName = sLog.option(form.Value, 'xray_usr_name', _('Xray 运行用户名'));
        oUsrName.description = _('Xray 进程的运行用户名，由 add_usr.sh 自动配置。');

        var oUsrGid = sLog.option(form.Value, 'xray_usr_gid', _('Xray 运行用户 GID'));
        oUsrGid.description = _('Xray 进程运行用户的 GID，nftables 通过此 GID 排除 Xray 自身流量。');

        return m.render().then(function (node) {
            /* 绑定所有更新按钮 (概览页) */
            var btns = node.querySelectorAll('[id^="xrayclient-update-btn"]');
            btns.forEach(function (btn) {
                btn.addEventListener('click', function () {
                    ui.showModal(_('数据更新'), [
                        E('p', { 'class': 'spinning' }, _('正在下载数据文件并重启服务，请稍候...'))
                    ]);

                    /* 临时提高 RPC 超时到 120 秒 (默认 20 秒不够下载大文件)
                     * rpcd 后端默认也是 120 秒，两者对齐 */
                    var oldTimeout = L.env.rpctimeout;
                    L.env.rpctimeout = 120;

                    /* 记录更新前所有数据文件的 mtime */
                    Promise.all(Object.keys(DATA_FILES).map(function (key) {
                        return fs.stat(DATA_FILES[key]).then(function (st) {
                            return { key: key, mtime: st.mtime };
                        }).catch(function () {
                            return { key: key, mtime: null };
                        });
                    })).then(function (beforeStats) {
                        return fs.exec(UPDATE_SCRIPT).then(function (res) {
                            L.env.rpctimeout = oldTimeout;
                            if (res.code !== 0) {
                                ui.hideModal();
                                ui.addNotification(null, E('p', _('数据更新失败 (exit code: %d)').format(res.code)));
                                window.setTimeout(function () { window.location.reload(); }, 2000);
                                return;
                            }
                            /* 更新后再次获取 mtime，对比判断是否有变化 */
                            Promise.all(Object.keys(DATA_FILES).map(function (key) {
                                return fs.stat(DATA_FILES[key]).then(function (st) {
                                    return { key: key, mtime: st.mtime };
                                }).catch(function () {
                                    return { key: key, mtime: null };
                                });
                            })).then(function (afterStats) {
                                ui.hideModal();
                                var changed = false;
                                for (var i = 0; i < afterStats.length; i++) {
                                    if (afterStats[i].mtime !== beforeStats[i].mtime) {
                                        changed = true;
                                        break;
                                    }
                                }
                                if (changed) {
                                    ui.addNotification(null, E('p', _('数据更新完成，请查看日志了解详情。')));
                                } else {
                                    ui.addNotification(null, E('p', _('数据已最新，无需更新！')));
                                }
                                window.setTimeout(function () { window.location.reload(); }, 2000);
                            });
                        });
                    }).catch(function (err) {
                        L.env.rpctimeout = oldTimeout;
                        ui.hideModal();
                        ui.addNotification(null, E('p', _('操作失败: %s').format(err.message || err)));
                    });
                });
            });

            /* 绑定"更新配置"跳转按钮 */
            var gotoBtn = node.querySelector('#xrayclient-goto-update-config');
            if (gotoBtn) {
                gotoBtn.addEventListener('click', function () {
                    /* LuCI tabbed map: <li class="cbi-tab-disabled" data-tab="更新配置"><a href="#">更新配置</a></li> */
                    var tabLi = document.querySelector('ul.cbi-tabmenu li[data-tab="更新配置"]');
                    if (tabLi) {
                        var link = tabLi.querySelector('a');
                        if (link) link.click();
                    }
                    window.scrollTo({ top: 0, behavior: 'smooth' });
                });
            }

            return node;
        });
    },

    handleSaveApply: function (ev, mode) {
        var self = this;
        var wasRunning = this.running;
        return this.handleSave(ev).then(function () {
            return ui.changes.apply();
        }).then(function () {
            /* 根据服务原状态 + 用户选择，决定 start/stop/restart */
            var activeNode = uci.get(UCI_CONF, 'main', 'active_node') || '';
            /* 两层判断: active_node 非空 && 对应 node 存在 */
            var nodeExists = false;
            if (activeNode) {
                var nodeSection = uci.get(UCI_CONF, activeNode);
                nodeExists = !!(nodeSection && nodeSection.protocol);
            }
            var action = null;

            if (nodeExists) {
                /* 用户选择了有效节点 */
                action = wasRunning ? 'restart' : 'start';
            } else if (wasRunning) {
                /* 用户选择了"停用"或节点已删除，服务原来在运行 */
                action = 'stop';
            }
            /* 服务未运行且选择停用 → 无需操作 */

            if (!action) return Promise.resolve();

            /* 通过 fs.exec 调用 init.d 脚本（需要 ACL 授权 file.exec）*/
            return fs.exec(INIT_SCRIPT, [action]).then(function (res) {
                if (res.code !== 0) {
                    throw new Error(_('服务 %s 失败 (exit code: %d)').format(action, res.code));
                }
            });
        }).catch(function (err) {
            ui.addNotification(null, E('p', _('操作失败: %s').format(err.message || err)));
        });
    }

    /* handleReset 使用基类默认实现：调用 uci.revert() 撤销未保存的修改 */
});
