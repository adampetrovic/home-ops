#!/usr/bin/env python3
#
# Helper script to do major version upgrades of a cloudnative-pg based
# PostgreSQL cluster.
#
# Usage: python3 upgrade-pg.py <cluster-name> <new-pg-version>
#
# Example: python3 upgrade-pg.py my-backend-db 16.0
#
# Make sure to include major and minor version in the pg version.
# Error handling is quite basic, when you're asked to check if the
# new database is ok, do so by checking if the relevant data is there.
# When in doubt, don't continue, as you could suffer data loss (especially
# if you have no backups configured).
#
# This script does the following:
# 1. Create a temporary cluster with the new PostgreSQL version
#    with data from the source cluster.
# 2. After confirmation, delete the original cluster (so we can replace it).
# 3. Create a new source cluster from the temporary cluster
# 4. After confirmation, delete the temporary cluster.
#
# Backups are disabled for the new cluster, as the new PostgreSQL version
# probably needs a new storage location, because the file formats may not
# be compatible.
#
# You need to make sure any subsequent infrastructure changes use the upgraded
# PostgreSQL version, and configure backup. Then take a new base backup.
#
# Note that the final cluster manifest needs some cleaning up yet.
#
# _NOTE:_ tested only a little, take care!
#
#
# Changelog:
#   20230918 initial version
#
import json
from subprocess import run
from random import randint
from time import sleep

def kubectl_get(kind, name):
    '''Return Kubernetes manifest for cluster'''
    r = run(['kubectl', 'get', kind, name, '-o', 'json'], check=True, capture_output=True)
    return json.loads(r.stdout)

def kubectl_create(manifest):
    '''Create Kubernetes resource from manifest'''
    run(['kubectl', 'create', '-f', '-'], check=True, input=manifest, text=True, capture_output=True)

def kubectl_delete(kind, name):
    '''Delete Kubernets resource'''
    run(['kubectl', 'delete', kind, name], check=True)

def kubectl_wait_cluster_ready(name, reverse=False):
    '''Wait until the cloudnative-pg cluster is ready'''
    ready_instances = 0
    while (not reverse and ready_instances == 0) or (reverse and ready_instances > 0):
        sleep(5)
        r = run(['kubectl', 'get', 'cluster', name, '-o', 'go-template={{ .status.readyInstances }}'], check=True, capture_output=True)
        s = r.stdout.decode().strip()
        if s and s != '<no value>': ready_instances = int(s)

class ClusterTemplate:
    def __init__(self, manifest):
        self.manifest = manifest

    @property
    def name(self):
        return self.manifest.get('metadata', {}).get('name')

    @name.setter
    def name(self, value):
        self.manifest.get('metadata', {})['name'] = value

    @property
    def spec(self):
        return self.manifest.get('spec', {})

    @property
    def database(self):
        return self.spec['bootstrap']['initdb']['database']

    @property
    def owner(self):
        return self.spec['bootstrap']['initdb']['owner']

    @property
    def secret(self):
        return self.spec['bootstrap']['initdb']['secret']['name']

    @property
    def imageName(self):
        return self.spec.get('imageName')

    @imageName.setter
    def imageName(self, value):
        self.spec['imageName'] = value

    @property
    def imageVersion(self):
        return self.imageName.split(':', 1)[-1]

    @imageVersion.setter
    def imageVersion(self, value):
        name, version = self.imageName.split(':', 1)
        self.imageName = name + ':' + value

    def delete_backup(self):
        if 'backup' in self.spec:
            self.spec.pop('backup')

    def import_from(self, name, database, user, secret):
        cluster_name = database + '-' + str(randint(0, 999999))
        # add external cluster for specified database
        if not self.spec.get('externalClusters'): self.spec['externalClusters'] = []
        self.spec['externalClusters'].append({
            'name': cluster_name,
            'connectionParameters': {
                'host': name + '-r',
                'user': user,
                'dbname': database
            },
            'password': {
                'name': secret,
                'key': 'password'
            }
        })
        # indicate to import from specified database
        self.spec['bootstrap']['initdb']['import'] = {
          'type': 'microservice',
          'databases': [database],
          'source': { 'externalCluster': cluster_name }
        }


if __name__ == '__main__':
    import re
    import sys

    name, new_version = sys.argv[1:3]
    new_name = name + '-' + re.sub(r'\.\d+$', '', new_version)

    print('Retrieving existing cluster template')
    template = ClusterTemplate(kubectl_get('cluster', name))
    template.name = new_name
    template.imageVersion = new_version
    template.delete_backup()
    template.import_from(name, template.database, template.owner, template.secret)

    print('Creating temporary upgraded database')
    kubectl_create(json.dumps(template.manifest))
    kubectl_wait_cluster_ready(new_name)

    s = input('Temporary upgraded database ready. Is it in order, continue and delete the source database? [y/n]')
    if s.lower() != 'y': sys.exit()

    print('Deleting source database (as to replace it)')
    kubectl_delete('cluster', name)
    kubectl_wait_cluster_ready(name, reverse=True)

    print('Re-creating source database')
    template.name = name
    template.import_from(new_name, template.database, template.owner, template.secret)
    kubectl_create(json.dumps(template.manifest))
    kubectl_wait_cluster_ready(name)

    s = input('Final upgraded database ready. Is it in order, continue and delete the temporary database? [y/n]')
    if s.lower() != 'y': sys.exit()

    print('Deleting temporary upgraded database')
    kubectl_delete('cluster', new_name)

    print('Done!')
    print('Remember to update your deployment configuration:')
    print('- set PostgreSQL version to ' + new_version)
    print('- use a new backup destination (als WALs will not be compatible)')
    print('- create a new base backup')