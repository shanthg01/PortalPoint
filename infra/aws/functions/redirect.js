// Decommission redirect: every request to the old CloudFront domain (app + /api)
// gets a 301 to the same path on the new frontend. Keeps old links (landing page,
// slides, submissions) working after the AWS backend is gone, and stops new
// signups/logins from landing in RDS. __TARGET__ is substituted by Terraform.
function handler(event) {
    var request = event.request;
    var parts = [];
    for (var key in request.querystring) {
        var param = request.querystring[key];
        if (param.multiValue) {
            param.multiValue.forEach(function (v) { parts.push(key + '=' + v.value); });
        } else {
            parts.push(param.value ? key + '=' + param.value : key);
        }
    }
    var location = '__TARGET__' + request.uri + (parts.length ? '?' + parts.join('&') : '');
    return {
        statusCode: 301,
        statusDescription: 'Moved Permanently',
        headers: {
            'location': { value: location },
            'cache-control': { value: 'max-age=3600' }
        }
    };
}
