worker_processes 1;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 6443 ssl;

        ssl_certificate /data/pki/apiserver.crt;
        ssl_certificate_key /data/pki/apiserver.key;
        ssl_verify_client off;
        ssl_protocols TLSv1.2 TLSv1.3;

        client_max_body_size 0;

        location = /.well-known/oauth-authorization-server {
            default_type application/json;
            alias /var/oauth-metadata/metadata.json;
        }

        location / {
            proxy_pass https://127.0.0.1:6444;
            proxy_ssl_certificate /data/pki/front-proxy-client.crt;
            proxy_ssl_certificate_key /data/pki/front-proxy-client.key;
            proxy_ssl_verify off;

            proxy_set_header X-Remote-User kubernetes-super-admin;
            proxy_set_header X-Remote-Group system:masters;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Host $host;

            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;

            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 30s;
            proxy_buffering off;
            proxy_request_buffering off;
        }
    }
}
