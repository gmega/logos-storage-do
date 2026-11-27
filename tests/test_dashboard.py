import importlib.util
import json
import subprocess
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('collector','dashboard/collector.py')
collector=importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)

class DashboardTests(unittest.TestCase):
    def test_required_service_missing_despite_four_other_entries(self):
        providers={name:[{}] for name in collector.REQUIRED_SERVICES}
        for version in ('1.0.0', '2.0.0'):
            self.assertTrue(collector.discovery_ready({**providers, '/storage/dht-proxy/'+version:[{}]}))
        providers['unrelated']=[{}]
        self.assertFalse(collector.discovery_ready(providers))
        self.assertFalse(collector.discovery_ready(None))

    def test_failed_node_does_not_break_other_snapshots(self):
        with patch.object(collector.subprocess,'run',side_effect=subprocess.TimeoutExpired('ssh',25)):
            result=collector.collect({'name':'node-1','ip':'192.0.2.1','role':'MP'})
        self.assertFalse(result['ok'])
        self.assertIn('error',result)

    def test_complete_debug_response_retained(self):
        value={'spr':'spr:example','serviceProviders':{name:[{}] for name in collector.REQUIRED_SERVICES},
               'unknownFutureField':{'value':123}}
        value['serviceProviders']['/storage/dht-proxy/2.0.0'] = [{}]
        response=subprocess.CompletedProcess([],0,json.dumps({'service':'active','version':'1.2.3',
            'debug':{'result':{'success':True,'value':value}}}), '')
        with patch.object(collector.subprocess,'run',return_value=response):
            result=collector.collect({'name':'node-1','ip':'192.0.2.1','role':'MP'})
        self.assertTrue(result['ok'])
        self.assertTrue(result['discoveryReady'])
        self.assertEqual(result['debug'],value)

if __name__=='__main__': unittest.main()
