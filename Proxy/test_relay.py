import base64
import copy
import http.client
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import uuid
from unittest.mock import patch

import server

ROOT = Path(__file__).resolve().parents[1]


def test_packet():
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory) / 'door.jpg'
        subprocess.run(['sips', '-Z', '460', str(ROOT / 'App/Resources/Practice/route-door.jpg'), '--out', str(out)], check=True, capture_output=True)
        image = out.read_bytes()
    width, height = server.jpeg_size(image)
    pose = {'sample': {'id': {'session': str(uuid.uuid4()).upper(), 'world': 1, 'frame': 18}, 'time': 4.0,
                       'transform': [1,0,0,0,0,1,0,0,0,0,1,0,0,1.4,0,1], 'intrinsics': [550,0,0,0,550,0,320,240,1],
                       'width': 640, 'height': 480, 'tracking': 'normal', 'exif': 1},
            'position': {'x':0,'y':1.4,'z':0}, 'heading': 0}
    ctx = dict(utterance='带我去教室门口', destination='教室门口', stage='环顾四周', trigger='first_observation', capture=pose,
               request=copy.deepcopy(pose), history=[], image_width=width, image_height=height, image_transform='full, upright',
               features=[], scanned_bins=[], known=[], recent_hazards=[], last_instruction='请站定', turned_since_instruction=0,
               moved_since_instruction=0, sign_history=[])
    ctx['request']['sample'].update(time=4.15)
    ctx['request']['sample']['id']['frame'] = 21
    return {'context': ctx, 'image': base64.b64encode(image).decode()}


def example(ctx):
    return {'frame_id': ctx['capture']['sample']['id'], 'observations': [{'ref':'o1','kind':'aisle_entrance','box':[0.1,0.3,0.4,0.8]}],
            'hazards': [], 'action':'target_waypoint', 'target_ref':'o1','speech_zh':'先转向左侧过道。','uncertain':False}


class RelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = test_packet()

    def setUp(self):
        self.packet = copy.deepcopy(self.template)

    def test_input_uses_real_jpeg_dimensions_and_two_poses(self):
        ctx, stamp = server.validate_input(self.packet)
        self.assertEqual(stamp['frame'], 18)
        self.assertEqual(ctx['request']['sample']['id']['frame'], 21)
        for modify in [lambda c:c.update(image_width=7), lambda c:c['request']['sample'].update(time=1),
                       lambda c:c['request']['sample']['id'].update(world=2), lambda c:c.update(features=[{'kind':'sign','box':[0,0,2,1],'confidence':1}])]:
            changed=copy.deepcopy(self.packet); modify(changed['context'])
            with self.assertRaises(ValueError): server.validate_input(changed)

    def test_prompt_and_exact_outbound_wire(self):
        ctx=self.packet['context']
        with patch('server.http.client.HTTPSConnection') as connection:
            reply=connection.return_value.getresponse.return_value; reply.status=200
            reply.read.return_value=json.dumps({'choices':[{'finish_reason':'stop','message':{'content':json.dumps(example(ctx))}}]}).encode()
            result=server.provider(ctx,self.packet['image'],'unit-test-only')
            connection.assert_called_once_with('api.deepseek.com',timeout=10)
            method,path,data,headers=connection.return_value.request.call_args.args
            body=json.loads(data); self.assertEqual((method,path),('POST','/chat/completions')); self.assertEqual(body['model'],'deepseek-flash')
            self.assertEqual(body['response_format'],{'type':'json_object'}); self.assertEqual(headers['Authorization'],'Bearer unit-test-only')
            self.assertNotIn('unit-test-only',str(body)); self.assertEqual(body['messages'][1]['content'][1]['image_url']['url'],'data:image/jpeg;base64,'+self.packet['image'])
            self.assertEqual(result,example(ctx)); self.assertIn('JSON',body['messages'][0]['content'])

    def test_rejects_malformed_model_data(self):
        ctx=self.packet['context']; stamp=ctx['capture']['sample']['id']
        for change in [dict(target_ref='missing'),dict(uncertain=True),dict(frame_id={**stamp,'frame':1}),dict(hazards=[{'ref':'o1','kind':'person','box':[0,0,.1,.9]}]),dict(observations=[{'ref':'o1','kind':'door','box':[.5,.2,.3,.4]}])]:
            with self.assertRaises(ValueError): server.validate_reply({**example(ctx),**change},stamp)

    def test_full_http_exchange_backpressure_and_sanitized_failures(self):
        gate=threading.Event(); entered=threading.Event()
        def planner(ctx,image,key):
            entered.set(); gate.wait(3)
            return example(ctx)
        with server.Server(('127.0.0.1',0),'test-value',planner) as srv:
            worker=threading.Thread(target=srv.serve_forever,daemon=True); worker.start()
            def call(path,packet=None):
                conn=http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=5)
                conn.request('POST',path,json.dumps(self.packet if packet is None else packet),{'Content-Type':'application/json'})
                response=conn.getresponse(); body=json.loads(response.read()); conn.close(); return response.status,body
            path='/'+srv.pair+'/next'; result=[]
            try:
                self.assertEqual(call('/wrong/next')[0],404)
                t=threading.Thread(target=lambda: result.append(call(path)));t.start(); self.assertTrue(entered.wait(2))
                self.assertEqual(call(path)[0],429);gate.set();t.join(4);self.assertEqual(result[0],(200,example(self.packet['context'])))
                self.assertEqual(call(path,{})[0],400)
                srv.planner=lambda *args: {'secret':'test-value'}
                self.assertEqual(call(path),(502,{'error':'planner_unavailable'}))
            finally:gate.set();srv.shutdown();worker.join(2)

if __name__=='__main__': unittest.main()
