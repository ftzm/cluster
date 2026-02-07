local config = import '../../lib/config.libsonnet';
local helm = (import 'tanka-util/helm.libsonnet').new(std.thisFile);
local k = import 'k8s-libsonnet/main.libsonnet';

// Cluster-scoped kinds that should not have namespace set
local clusterScoped = [
  'ClusterRole',
  'ClusterRoleBinding',
  'StorageClass',
  'Namespace',
  'IngressClass',
  'CustomResourceDefinition',
  'GatewayClass',
];

// Add namespace to all namespaced resources
local withNamespace(resources, ns) = {
  [key]: resources[key] + (
    if std.member(clusterScoped, resources[key].kind)
    then {}
    else { metadata+: { namespace: ns } }
  )
  for key in std.objectFields(resources)
};

{
  nfsProvisioner: {
    namespace: k.core.v1.namespace.new('nfs-provisioner'),

    resources: withNamespace(
      helm.template('nfs-provisioner', '../../charts/nfs-subdir-external-provisioner', {
        namespace: 'nfs-provisioner',
        values: {
          nfs: {
            server: config.nasIP,
            path: '/pool-1/k8s',
          },
          storageClass: {
            name: 'nfs',
            defaultClass: true,
          },
        },
      }),
      'nfs-provisioner'
    ),
  },

  // Test app to verify NFS provisioning
  storageTest: {
    local ns = 'storage-test',

    namespace: k.core.v1.namespace.new(ns),

    pvc: k.core.v1.persistentVolumeClaim.new('test-pvc')
      + k.core.v1.persistentVolumeClaim.metadata.withNamespace(ns)
      + k.core.v1.persistentVolumeClaim.spec.withAccessModes(['ReadWriteMany'])
      + k.core.v1.persistentVolumeClaim.spec.resources.withRequests({ storage: '100Mi' }),

    pod: k.core.v1.pod.new('storage-test')
      + k.core.v1.pod.metadata.withNamespace(ns)
      + k.core.v1.pod.spec.withContainers([
        k.core.v1.container.new('busybox', 'busybox')
        + k.core.v1.container.withCommand(['/bin/sh', '-c', 'echo "Written at $(date)" >> /data/test.txt && cat /data/test.txt && sleep 3600'])
        + k.core.v1.container.withVolumeMounts([
          k.core.v1.volumeMount.new('data', '/data'),
        ]),
      ])
      + k.core.v1.pod.spec.withVolumes([
        k.core.v1.volume.fromPersistentVolumeClaim('data', 'test-pvc'),
      ]),
  },

  // Hello world to test internal ingress
  helloWorld: {
    local ns = 'hello-world',
    local labels = { app: 'hello' },

    namespace: k.core.v1.namespace.new(ns),

    deployment: k.apps.v1.deployment.new('hello')
    + k.apps.v1.deployment.metadata.withNamespace(ns)
    + k.apps.v1.deployment.spec.withReplicas(1)
    + k.apps.v1.deployment.spec.selector.withMatchLabels(labels)
    + k.apps.v1.deployment.spec.template.metadata.withLabels(labels)
    + k.apps.v1.deployment.spec.template.spec.withContainers([
      k.core.v1.container.new('nginx', 'nginx:alpine')
      + k.core.v1.container.withPorts([
        k.core.v1.containerPort.newNamed(80, 'http'),
      ]),
    ]),

    service: k.core.v1.service.new('hello', labels, [
      k.core.v1.servicePort.new(80, 80),
    ])
    + k.core.v1.service.metadata.withNamespace(ns),

    // IngressRoute for private-only access (WireGuard only)
    // To make this public too, add 'web' and 'websecure' to entryPoints
    ingressRoute: {
      apiVersion: 'traefik.io/v1alpha1',
      kind: 'IngressRoute',
      metadata: {
        name: 'hello',
        namespace: ns,
      },
      spec: {
        entryPoints: ['privateweb', 'privatesecure'],
        routes: [
          {
            match: "Host(`hello.ftzmlab.xyz`)",
            kind: 'Rule',
            services: [
              {
                name: 'hello',
                port: 80,
              },
            ],
          },
        ],
      },
    },
  },

  // Traefik ingress controller with dual entrypoints
  // - Public entrypoints (web, websecure) bind to LAN IP
  // - Private entrypoints (privateweb, privatesecure) bind to WireGuard IP
  traefik: {
    local ns = 'traefik',

    namespace: k.core.v1.namespace.new(ns),

    resources: withNamespace(
      helm.template('traefik', '../../charts/traefik', {
        namespace: ns,
        values: {
          // Use host network to bind directly to specific IPs
          hostNetwork: true,

          deployment: {
            // Required when using hostNetwork to resolve cluster DNS
            dnsPolicy: 'ClusterFirstWithHostNet',
          },

          // Ensure Traefik runs on the node with both IPs (public + WireGuard)
          nodeSelector: {
            'kubernetes.io/hostname': 'nuc',
          },


          // Disable LoadBalancer service - we bind directly via hostNetwork
          service: {
            enabled: false,
          },

          // Disable default ports exposure (we use hostNetwork)
          ports: {
            web: {
              expose: { default: false },
            },
            websecure: {
              expose: { default: false },
            },
            traefik: {
              expose: { default: false },
            },
            metrics: {
              expose: { default: false },
            },
          },

          // Define entrypoints with specific IP bindings
          // Using non-privileged ports since nginx handles 80/443 on the host
          additionalArguments: [
            // Public entrypoints (bind to LAN IP)
            '--entrypoints.web.address=' + config.publicIP + ':9080',
            '--entrypoints.websecure.address=' + config.publicIP + ':9443',
            // Private entrypoints (bind to WireGuard IP)
            '--entrypoints.privateweb.address=' + config.wireguardIP + ':9080',
            '--entrypoints.privatesecure.address=' + config.wireguardIP + ':9443',
          ],

          // Single IngressClass for standard Ingress resources
          // Note: Standard Ingress resources will be available on ALL entrypoints.
          // Use IngressRoute CRD with entryPoints field for private-only services.
          ingressClass: {
            enabled: true,
            isDefaultClass: true,
          },
        },
      }),
      ns
    ),
  },

  // ArgoCD - GitOps continuous delivery
  argocd: {
    local ns = 'argocd',

    namespace: k.core.v1.namespace.new(ns),

    resources: withNamespace(
      helm.template('argocd', '../../charts/argo-cd', {
        namespace: ns,
        values: {
          // Use existing CRDs if already installed
          crds: {
            install: true,
            keep: true,
          },
          // Only needed for initial install to create redis secret.
          // Keep disabled because it causes problems during syncs.
          redisSecretInit: {
            enabled: false,
          },
        },
      }),
      ns
    ),

    // Application that points ArgoCD at this repo's rendered manifests
    app: {
      apiVersion: 'argoproj.io/v1alpha1',
      kind: 'Application',
      metadata: {
        name: 'lab',
        namespace: ns,
      },
      spec: {
        project: 'default',
        source: {
          repoURL: 'https://github.com/ftzm/cluster.git',
          targetRevision: 'HEAD',
          path: 'manifests/lab',
        },
        destination: {
          server: 'https://kubernetes.default.svc',
          namespace: 'default',
        },
        syncPolicy: {
          automated: {
            prune: false,  // Don't auto-delete resources not in Git (safer)
            selfHeal: true,  // Auto-sync when cluster state drifts
          },
          syncOptions: [
            'ServerSideApply=true',
          ],
        },
      },
    },
  },
}
