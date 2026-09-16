var fs = require('fs');

var tokenPath = '/var/run/secrets/kubernetes.io/serviceaccount/token';

function hostAPI() {
    var host = process.env.KUBERNETES_SERVICE_HOST || '172.30.0.1';
    var port = process.env.KUBERNETES_SERVICE_PORT || '443';
    return 'https://' + host + ':' + port;
}

function readToken() {
    return fs.readFileSync(tokenPath).toString().trim();
}

function buildHeaders(r) {
    var token = readToken();
    var user = r.headersIn['X-Remote-User'];
    if (!user) {
        return null;
    }

    var headers = new Headers({
        'Authorization': 'Bearer ' + token,
        'Impersonate-User': user
    });

    for (var i = 0; i < r.rawHeadersIn.length; i++) {
        if (r.rawHeadersIn[i][0].toLowerCase() === 'x-remote-group') {
            headers.append('Impersonate-Group', r.rawHeadersIn[i][1]);
        }
    }

    return headers;
}

async function proxyToHost(r) {
    var headers = buildHeaders(r);
    if (!headers) {
        r.return(401, JSON.stringify({
            kind: 'Status', apiVersion: 'v1', status: 'Failure',
            message: 'no authenticated user identity',
            reason: 'Unauthorized', code: 401
        }));
        return;
    }

    var url = hostAPI() + r.uri;
    var args = r.variables.args;
    if (args) { url += '?' + args; }

    try {
        var resp = await ngx.fetch(url, {
            method: 'GET',
            headers: headers,
            verify: false
        });
        var body = await resp.text();
        r.headersOut['Content-Type'] = resp.headers.get('Content-Type') || 'application/json';
        r.return(resp.status, body);
    } catch (e) {
        r.return(502, JSON.stringify({
            kind: 'Status', apiVersion: 'v1', status: 'Failure',
            message: 'upstream error: ' + e.toString(),
            reason: 'BadGateway', code: 502
        }));
    }
}

async function readOnlyProxy(r) {
    if (r.method !== 'GET') {
        r.return(405, JSON.stringify({
            kind: 'Status', apiVersion: 'v1', status: 'Failure',
            message: 'write operations are not supported on projected host resources',
            reason: 'MethodNotAllowed', code: 405
        }));
        return;
    }
    return proxyToHost(r);
}

export default { proxyToHost, readOnlyProxy };
