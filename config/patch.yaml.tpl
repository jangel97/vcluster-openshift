spec:
  template:
    spec:
      containers:
      - name: syncer
        volumeMounts:
        - mountPath: /etc/webhook
          name: webhook-token-auth
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
      - name: openshift-compat-proxy
        image: NGINX_IMAGE
        ports:
        - containerPort: 6443
          name: api-proxy
        - containerPort: 8446
          name: user-api
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
      - name: webhook-token-auth
        configMap:
          name: webhook-token-auth
