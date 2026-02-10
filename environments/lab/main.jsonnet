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

  // Sealed Secrets controller for encrypted secrets in git
  sealedSecrets: {
    local ns = 'sealed-secrets',

    namespace: k.core.v1.namespace.new(ns),

    resources: withNamespace(
      helm.template('sealed-secrets', '../../charts/sealed-secrets', {
        namespace: ns,
        values: {},
      }),
      ns
    ),
  },

  // Observability stack: Prometheus, Grafana, Loki, Tempo, Alloy
  monitoring: {
    local ns = 'monitoring',

    namespace: k.core.v1.namespace.new(ns),

    // kube-prometheus-stack: Prometheus + Grafana + Alertmanager
    prometheusStack: withNamespace(
      helm.template('kube-prometheus-stack', '../../charts/kube-prometheus-stack', {
        namespace: ns,
        values: {
          prometheus: {
            prometheusSpec: {
              storageSpec: {
                volumeClaimTemplate: {
                  spec: {
                    storageClassName: 'nfs',
                    accessModes: ['ReadWriteOnce'],
                    resources: {
                      requests: { storage: '20Gi' },
                    },
                  },
                },
              },
              retention: '30d',
              retentionSize: '18GB',
              // Discover all ServiceMonitors/PodMonitors, not just those with release label
              podMonitorSelectorNilUsesHelmValues: false,
              serviceMonitorSelectorNilUsesHelmValues: false,
            },
          },
          alertmanager: {
            alertmanagerSpec: {
              storage: {
                volumeClaimTemplate: {
                  spec: {
                    storageClassName: 'nfs',
                    accessModes: ['ReadWriteOnce'],
                    resources: {
                      requests: { storage: '1Gi' },
                    },
                  },
                },
              },
            },
          },
          grafana: {
            admin: {
              existingSecret: 'grafana-admin',
              userKey: 'admin-user',
              passwordKey: 'admin-password',
            },
            persistence: {
              enabled: true,
              storageClassName: 'nfs',
              size: '1Gi',
            },
            additionalDataSources: [
              {
                name: 'Loki',
                type: 'loki',
                url: 'http://loki-gateway.monitoring.svc.cluster.local:80',
                access: 'proxy',
              },
              {
                name: 'Tempo',
                type: 'tempo',
                uid: 'tempo',
                url: 'http://tempo.monitoring.svc.cluster.local:3100',
                access: 'proxy',
              },
            ],
            ingress: { enabled: false },
            sidecar: {
              dashboards: { enabled: true, searchNamespace: 'ALL' },
              datasources: { enabled: true },
            },
          },
          // Disable components not accessible in homelab k8s
          kubeEtcd: { enabled: false },
          kubeControllerManager: { enabled: false },
          kubeScheduler: { enabled: false },
          kubeProxy: { enabled: false },
        },
      }),
      ns
    ),

    // Loki: Log aggregation (monolithic mode)
    loki: withNamespace(
      helm.template('loki', '../../charts/loki', {
        namespace: ns,
        values: {
          deploymentMode: 'SingleBinary',
          loki: {
            auth_enabled: false,
            commonConfig: { replication_factor: 1 },
            storage: { type: 'filesystem' },
            schemaConfig: {
              configs: [{
                from: '2024-01-01',
                store: 'tsdb',
                object_store: 'filesystem',
                schema: 'v13',
                index: { prefix: 'index_', period: '24h' },
              }],
            },
            limits_config: {
              retention_period: '720h',
            },
            compactor: {
              retention_enabled: true,
              delete_request_store: 'filesystem',
            },
          },
          singleBinary: {
            replicas: 1,
            persistence: {
              enabled: true,
              storageClass: 'nfs',
              size: '20Gi',
            },
          },
          backend: { replicas: 0 },
          read: { replicas: 0 },
          write: { replicas: 0 },
          gateway: { enabled: true, replicas: 1 },
          minio: { enabled: false },
          test: { enabled: false },
          lokiCanary: { enabled: false },
        },
      }),
      ns
    ),

    // Tempo: Distributed tracing
    tempo: withNamespace(
      helm.template('tempo', '../../charts/tempo', {
        namespace: ns,
        values: {
          tempo: {
            retention: '336h',  // 14 days (Tempo recommended default)
            receivers: {
              otlp: {
                protocols: {
                  grpc: { endpoint: '0.0.0.0:4317' },
                  http: { endpoint: '0.0.0.0:4318' },
                },
              },
            },
          },
          persistence: {
            enabled: true,
            storageClassName: 'nfs',
            size: '10Gi',
          },
        },
      }),
      ns
    ),

    // Alloy: Unified collector for logs and traces
    alloy: withNamespace(
      helm.template('alloy', '../../charts/alloy', {
        namespace: ns,
        values: {
          alloy: {
            configMap: {
              content: |||
                // Kubernetes pod log discovery
                discovery.kubernetes "pods" {
                  role = "pod"
                }

                // Collect logs from all pods
                loki.source.kubernetes "pods" {
                  targets    = discovery.kubernetes.pods.targets
                  forward_to = [loki.write.default.receiver]
                }

                // Write logs to Loki
                loki.write "default" {
                  endpoint {
                    url = "http://loki-gateway.monitoring.svc.cluster.local:80/loki/api/v1/push"
                  }
                }

                // OTLP receiver for traces from instrumented apps
                otelcol.receiver.otlp "default" {
                  grpc { endpoint = "0.0.0.0:4317" }
                  http { endpoint = "0.0.0.0:4318" }
                  output {
                    traces = [otelcol.processor.batch.default.input]
                  }
                }

                // Batch processor for better performance
                otelcol.processor.batch "default" {
                  output {
                    traces = [otelcol.exporter.otlp.tempo.input]
                  }
                }

                // Export traces to Tempo
                otelcol.exporter.otlp "tempo" {
                  client {
                    endpoint = "tempo.monitoring.svc.cluster.local:4317"
                    tls { insecure = true }
                  }
                }
              |||,
            },
          },
          controller: { type: 'daemonset' },
          serviceAccount: { create: true },
          rbac: { create: true },
        },
      }),
      ns
    ),

    // Sealed secret for Grafana admin credentials
    grafanaAdminSecret: {
      apiVersion: 'bitnami.com/v1alpha1',
      kind: 'SealedSecret',
      metadata: {
        name: 'grafana-admin',
        namespace: ns,
      },
      spec: {
        encryptedData: {
          'admin-password': 'AgAcMAQk1+wFcejscOkHWUqhpiV2Xe4o8zTFMWkxMNpiUkgRe+zxU1iOEiTyjucegxoKrY+1jb5u6geCX/21yF5PI58QVymgGuo5mNdHkPzHKFFUXvgmr0MUQeReFVWo6A1Msyhvnk2wYZLmHIyqPaFJLK5IcRdeTfCry1N8VGVt7bn/2tul4Ka+ahrculnLy4cXEhTj9ciMJeXQFB2D2JvXdZahJM+KuToIYtLp3LnYUJe0LCCpCEaFz6m3n9Q62LXOgVrVAp4kpRzSqS34fVAcGrQ9KUdImsPhH0WKDdmq2yyiXw1Q4O1AjrWnvwUpKkfludvkmt1UyPStyhJ464XrJ8uL3zejX5QS6vWTnQKp0fJpXriEyKWKAeo7pRCjfJWkQ0fO5KnFqke94UVcb7A1ohIivifCej97bK+jELFUgLfFirTTUQcvdmWzj/+9GvD3GFn6PSpNvJQ35xrGb1rw7xcXQ8R5uw2gHmpfAMeqC3rw3NDlkUE8PSauFPAh48TGAcl99oNYZ3Wkt/ubvU5pIBfYOC5YejXcfIwC9BRWvQvEhd+YqX9WsDpmbzk9Tax5aKoRkABgMROTquXPhi1hm+BD2RI6QD46FD+d3L21FK34bWSVQz2QoairWCacSVSiXk+v7lXRCIiAdVk76JXMaeQBM1L4dUAs6C8HMoK7IKm+eFcKQs33MWJmsf94NY7IG1pOB0gCwL/ul2K2CHE3AAkEwJMTjh0NtESgq2Lq6w==',
          'admin-user': 'AgAwE50JHLsXlT14+/gMcC5/1Zg/nzCAvsg9pYfyHAICf99gJMZeXnVhOpst4Jt13mpwf1OQeEiKaP+Tq2SNYM0LdOywZmthOtVsM3pgzqQzuQfSuVNJ5rLLcArvoWaQh/vNqznFinXtC+9n0iVqQqCduF/iEzsC2p55R5xKLtNlFLE6BS+8N/UyS+E3mmML3WQSEqGbAFg5LcBsQTcx4ET9cGdFpsiKAt0dGiupC3uCrUBn5vybZK9cYqwBZDV2O9C83d9WIAIc9wKsCBu1oLIPXJHSOpbXuDW64i1p2yDbVnAcAR662iq2WMv1eCvXgHdhV0r/k8f2vGOYJy2106GkJc+F5tT5DND8T+mL/j/f2wn5JRa+eIIMvNiZbk55n0pZTorkWKTlZQGg2v3usICNFqaqRdlCmmHXkNVL+3j2DZuP8TUBE6nwrI4nWw3wafmyYVEv8l2DB4EypdhXVR/+R4MC8mRNIABUPpAW1Co9QUUXOFokYU/fMeCHWhGC6mofVNDH+IElzoX11vcXCAErwbOutPemeZNug6eyIJg9k2dl8iSVQCzsfkhxrr5hv+Dq6gdcV8glOvx02QG/vjzeTw4Q/+FCMOX9pwofUbfES3VJZ+gx01j3heD022vaH6YVoeh/rkQXV/dpNMv+AAHWDsJCWn9mEy08UqC32WtkDnau5cuYD0XXrM2xVDcjB/YX1t1s4g==',
        },
        template: {
          metadata: {
            name: 'grafana-admin',
            namespace: ns,
          },
        },
      },
    },

    // Traefik IngressRoute for Grafana (private/WireGuard only)
    grafanaIngress: {
      apiVersion: 'traefik.io/v1alpha1',
      kind: 'IngressRoute',
      metadata: {
        name: 'grafana',
        namespace: ns,
      },
      spec: {
        entryPoints: ['privateweb', 'privatesecure'],
        routes: [{
          match: "Host(`grafana.ftzmlab.xyz`)",
          kind: 'Rule',
          services: [{
            name: 'kube-prometheus-stack-grafana',
            port: 80,
          }],
        }],
      },
    },
  },
}
