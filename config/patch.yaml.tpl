spec:
  template:
    spec:
      initContainers:
      - name: copy-hyperkube
        image: HYPERKUBE_IMAGE
        command: ["/bin/bash", "-c", "cp /usr/bin/kube-apiserver /binaries/ocp-kube-apiserver && mkdir -p /binaries/lib64 && cp /lib64/ld-linux-x86-64.so.2 /lib64/libc.so.6 /lib64/libresolv.so.2 /binaries/lib64/"]
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /binaries
          name: binaries
      containers:
      - name: syncer
        volumeMounts:
        - mountPath: /etc/webhook
          name: webhook-token-auth
          readOnly: true
        - mountPath: /var/ocp-kas-config
          name: ocp-kas-config
          readOnly: true
      - name: openshift-etcd
        image: ETCD_IMAGE
        command:
        - etcd
        - --data-dir=/var/etcd/data
        - --listen-client-urls=https://127.0.0.1:ETCD_CLIENT_PORT
        - --advertise-client-urls=https://127.0.0.1:ETCD_CLIENT_PORT
        - --listen-peer-urls=https://127.0.0.1:ETCD_PEER_PORT
        - --cert-file=/data/pki/etcd/server.crt
        - --key-file=/data/pki/etcd/server.key
        - --trusted-ca-file=/data/pki/etcd/ca.crt
        - --client-cert-auth=true
        - --peer-cert-file=/data/pki/etcd/peer.crt
        - --peer-key-file=/data/pki/etcd/peer.key
        - --peer-trusted-ca-file=/data/pki/etcd/ca.crt
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
        - mountPath: /var/etcd
          name: openshift-etcd-data
          subPath: etcd
      - name: openshift-apiserver
        image: OPENSHIFT_APISERVER_IMAGE
        command:
        - openshift-apiserver
        - start
        - --config=/var/config/config.yaml
        - --authentication-kubeconfig=/data/pki/admin.conf
        - --authorization-kubeconfig=/data/pki/admin.conf
        - --requestheader-client-ca-file=/data/pki/front-proxy-ca.crt
        - --requestheader-allowed-names=front-proxy-client
        - --requestheader-extra-headers-prefix=X-Remote-Extra-
        - --requestheader-group-headers=X-Remote-Group
        - --requestheader-username-headers=X-Remote-User
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "127.0.0.1"
        - name: KUBERNETES_SERVICE_PORT
          value: "6444"
        ports:
        - containerPort: OPENSHIFT_APISERVER_PORT
          name: https
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
        - mountPath: /var/config
          name: openshift-apiserver-config
        - mountPath: /var/serving-cert
          name: openshift-apiserver-serving-cert
      - name: openshift-controller-manager
        image: OCM_IMAGE
        command:
        - openshift-controller-manager
        - start
        - --config=/var/ocm-config/config.yaml
        - --kubeconfig=/data/pki/admin.conf
        - --namespace=openshift-controller-manager
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "127.0.0.1"
        - name: KUBERNETES_SERVICE_PORT
          value: "6444"
        ports:
        - containerPort: OCM_PORT
          name: https
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
        - mountPath: /var/ocm-config
          name: openshift-controller-manager-config
        - mountPath: /var/serving-cert
          name: openshift-apiserver-serving-cert
      - name: cluster-policy-controller
        image: CPC_IMAGE
        command:
        - cluster-policy-controller
        - start
        - --config=/var/cpc-config/config.yaml
        - --kubeconfig=/data/pki/admin.conf
        - --namespace=openshift-kube-controller-manager
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "127.0.0.1"
        - name: KUBERNETES_SERVICE_PORT
          value: "6444"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
        - mountPath: /var/cpc-config
          name: cluster-policy-controller-config
        - mountPath: /var/serving-cert
          name: openshift-apiserver-serving-cert
      - name: openshift-oauth-apiserver
        image: OAUTH_APISERVER_IMAGE
        command:
        - /usr/bin/oauth-apiserver
        - start
        - --authorization-kubeconfig=/data/pki/admin.conf
        - --authentication-kubeconfig=/data/pki/admin.conf
        - --kubeconfig=/data/pki/admin.conf
        - --secure-port=OAUTH_APISERVER_PORT
        - --etcd-cafile=/data/pki/etcd/ca.crt
        - --etcd-keyfile=/data/pki/apiserver-etcd-client.key
        - --etcd-certfile=/data/pki/apiserver-etcd-client.crt
        - --etcd-servers=https://127.0.0.1:ETCD_CLIENT_PORT
        - --tls-private-key-file=/var/serving-cert/tls.key
        - --tls-cert-file=/var/serving-cert/tls.crt
        - --audit-log-path=-
        - --audit-log-maxsize=0
        - --audit-policy-file=/var/oauth-audit/policy.yaml
        - --shutdown-delay-duration=3s
        - --requestheader-client-ca-file=/data/pki/front-proxy-ca.crt
        - --requestheader-allowed-names=front-proxy-client
        - --requestheader-username-headers=X-Remote-User
        - --requestheader-group-headers=X-Remote-Group
        - --requestheader-extra-headers-prefix=X-Remote-Extra-
        - --client-ca-file=/data/pki/client-ca.crt
        env:
        - name: KUBERNETES_SERVICE_HOST
          value: "127.0.0.1"
        - name: KUBERNETES_SERVICE_PORT
          value: "6444"
        ports:
        - containerPort: OAUTH_APISERVER_PORT
          name: https
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
        - mountPath: /var/serving-cert
          name: openshift-apiserver-serving-cert
        - mountPath: /var/oauth-audit
          name: oauth-apiserver-audit-config
      - name: openshift-compat-proxy
        image: NGINX_IMAGE
        ports:
        - containerPort: 6443
          name: api-proxy
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: RUN_AS_USER
        volumeMounts:
        - mountPath: /data
          name: data
          readOnly: true
        - mountPath: /etc/nginx/nginx.conf
          name: openshift-compat-proxy-config
          subPath: nginx.conf
          readOnly: true
        - mountPath: /etc/nginx/proxy.js
          name: openshift-compat-proxy-config
          subPath: proxy.js
          readOnly: true
      volumes:
      - name: openshift-apiserver-config
        configMap:
          name: openshift-apiserver-config
      - name: openshift-apiserver-serving-cert
        secret:
          secretName: openshift-apiserver-serving-cert
      - name: openshift-etcd-data
        emptyDir: {}
      - name: openshift-compat-proxy-config
        configMap:
          name: openshift-compat-proxy-config
      - name: openshift-controller-manager-config
        configMap:
          name: openshift-controller-manager-config
      - name: cluster-policy-controller-config
        configMap:
          name: cluster-policy-controller-config
      - name: oauth-apiserver-audit-config
        configMap:
          name: oauth-apiserver-audit-config
      - name: webhook-token-auth
        configMap:
          name: webhook-token-auth
      - name: ocp-kas-config
        configMap:
          name: ocp-kas-config
