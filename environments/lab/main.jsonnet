local config = import '../../lib/config.libsonnet';
local helm = (import 'tanka-util/helm.libsonnet').new(std.thisFile);
local k = import 'k8s-libsonnet/main.libsonnet';

{
  nfsProvisioner: {
    namespace: k.core.v1.namespace.new('nfs-provisioner'),

    resources: helm.template('nfs-provisioner', '../../charts/nfs-subdir-external-provisioner', {
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
  },
}
