import copy
from contextlib import redirect_stdout
import http.client
import io
import json
from pathlib import Path
import ssl
import threading
import unittest
import uuid
from unittest.mock import patch

import server
import smoke_sign

def setUpModule():
    # A missed mock must fail closed rather than resolve credentials or make an external connection.
    for target in ('server.demo_key', 'server.http.client.HTTPSConnection'):
        guard = patch(target, side_effect=AssertionError('live provider disabled in unit tests'))
        guard.start()
        unittest.addModuleCleanup(guard.stop)


def text_packet():
    ctx = smoke_sign.make_context(640, 480, str(uuid.uuid4()).upper())
    return {'context':ctx, 'image':'TEXT-ONLY-TEST-PLACEHOLDER'}


def example(ctx):
    return {'frame_id': ctx['capture']['sample']['id'], 'observations': [{'ref':'o1','kind':'aisle_entrance','box':[0.1,0.3,0.4,0.8]}],
            'hazards': [], 'action':'target_waypoint', 'target_ref':'o1','speech_zh':'先转向左侧过道。','uncertain':False}


def contract_cases(ctx):
    base = example(ctx)
    item = dict(base['observations'][0], kind='sign')
    def observation(**extra):
        return dict(base, observations=[dict(item, **extra)])

    yield 'legacy sign without meaning', True, observation()
    yield 'nullable sign', True, observation(sign=None)
    for symbol in sorted(server.SIGN_SYMBOLS - {'unknown'}):
        yield symbol, True, observation(sign={'symbol': symbol})
    for arrow in sorted(server.SIGN_ARROWS):
        yield arrow, True, observation(sign={'symbol':'unknown', 'text':'松间书屋', 'arrow':arrow})
    yield 'null optional keys', True, observation(sign={'symbol':'exit', 'text':None, 'arrow':None})
    yield '48 scalars', True, observation(sign={'symbol':'room', 'text':'0' * 48})
    for bad in [False, [], {}, {'symbol':None}, {'symbol':'hospital'}, {'symbol':'unknown'},
                {'arrow':'←'}, {'symbol':'unknown','arrow':'↙'}, {'symbol':'unknown','text':'←','arrow':'←'},
                {'symbol':'directory','text':'书屋 →'}, {'symbol':'exit','arrow':'left'}, {'symbol':'exit','arrow':'➡'},
                {'symbol':'exit','arrow':[]}, {'symbol':'room','row':2}, {'symbol':'room','text':5},
                {'symbol':'room','text':''}, {'symbol':'room','text':'  '}, {'symbol':'shop','text':'A\nB'},
                {'symbol':'shop','text':'A\x7fB'}, {'symbol':'clinic','text':'A\u202eB'},
                {'symbol':'room','text':'A\u2028B'}, {'symbol':'room','text':'e\u0301' * 25}]:
        yield f'invalid meaning {bad!r}', False, observation(sign=bad)
    for change in [dict(kind='door',sign=None), dict(kind='steps',sign={'symbol':'stairs'}), dict(arrow='↖'),
                   dict(symbol='elevator',arrow='←'),
                   dict(frame_id=base['frame_id']), dict(ref='o1\n'), dict(ref='1door'), dict(ref='o' * 25),
                   dict(kind='person'), dict(box=[False,0,.4,.8])]:
        yield f'invalid item {change!r}', False, observation(**change)
    duplicate = dict(item, kind='person')
    stamp = base['frame_id']
    for change in [dict(hazards=[duplicate]), dict(hazards=[dict(item,ref='h2')]), dict(uncertain=True),
                   dict(target_ref='missing'), dict(action='wait'), dict(target_ref=6), dict(speech_zh='等\n待'),
                   dict(speech_zh='  '), dict(speech_zh='A' * 65), dict(other=1),
                   dict(frame_id=dict(stamp, frame=ctx['request']['sample']['id']['frame'])),
                   dict(frame_id=stamp['session']), dict(frame_id=dict(stamp, session=str(uuid.uuid4()))), dict(frame_id=dict(stamp, world=2)),
                   dict(frame_id=dict(stamp, world=True)), dict(frame_id=dict(stamp, frame=float(stamp['frame']))),
                   dict(frame_id=dict(stamp, ref='other'))]:
        yield f'invalid reply {tuple(change)}', False, dict(base, **change)
    held = dict(base, action='wait', target_ref=None, uncertain=True)
    for action, speech in [('wait','请先站定。'), ('wait','先停一下。'), ('rescan','请站定，慢慢补扫四周。'),
                           ('wait','可以慢慢转动手机，看看周围。'), ('rescan','请慢慢转动手机，补扫周围。')]:
        yield speech, True, dict(held, action=action, speech_zh=speech)
    yield 'verify prompt', True, dict(base, action='verify_destination', speech_zh='转动手机，看看目的地的标识。')
    yield 'missing null key', False, {k:v for k,v in held.items() if k != 'target_ref'}


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.packet = text_packet()

    def test_input_validates_image_at_boundary_and_two_poses(self):
        with patch('server.validate_image') as check_image:
            ctx, stamp = server.validate_input(self.packet)
            check_image.assert_called_once_with(self.packet['image'], 640, 480)
        self.assertEqual(stamp['frame'], 18)
        self.assertEqual(ctx['request']['sample']['id']['frame'], 19)
        with self.assertRaises(ValueError):  # The actual JPEG boundary rejects the text placeholder.
            server.validate_input(self.packet)
        for modify in [lambda c:c.update(image_width=1025), lambda c:c['request']['sample'].update(time=1),
                       lambda c:c['request']['sample']['id'].update(world=2), lambda c:c.update(features=[{'kind':'sign','box':[0,0,2,1],'confidence':1}])]:
            changed=copy.deepcopy(self.packet); modify(changed['context'])
            with patch('server.validate_image'), self.assertRaises(ValueError): server.validate_input(changed)

    def test_examples_are_whole_strict_replies_with_this_capture_id(self):
        ctx = self.packet['context']
        stamp = ctx['capture']['sample']['id']
        prompt = server.planner_prompt(stamp)
        examples = [json.loads(line) for line in prompt.splitlines() if line.startswith('{')]
        self.assertEqual(len(examples), 2)
        for reply in examples:
            self.assertEqual(server.validate_reply(reply, stamp), reply)
            self.assertEqual(reply['frame_id'], stamp)
        self.assertNotEqual(examples[0]['frame_id'], ctx['request']['sample']['id'])
        self.assertEqual(examples[0]['observations'][0]['kind'], 'aisle_entrance')
        self.assertEqual(examples[0]['hazards'][0]['kind'], 'chair')
        self.assertEqual(examples[1]['observations'][0]['sign']['symbol'], 'restroom')
        for key in ('features', 'known', 'sign_history', 'history', 'recent_hazards'):
            self.assertEqual(ctx[key], [])
        current = server.planner_prompt(dict(stamp, frame=73))
        self.assertNotIn('"frame":18', current)
        self.assertIn('"frame":73', current)

    def test_prompt_and_exact_outbound_wire(self):
        ctx=self.packet['context']
        ctx['utterance'] = 'private user utterance'
        with patch('server.http.client.HTTPSConnection') as connection:
            reply=connection.return_value.getresponse.return_value; reply.status=200
            reply.read.return_value=json.dumps({'choices':[{'finish_reason':'stop','message':{'content':json.dumps(example(ctx))}}]}).encode()
            result=server.provider(ctx,self.packet['image'],'unit-test-only')
            connection.assert_called_once()
            args, kwargs = connection.call_args
            self.assertEqual(args, ('api.deepseek.com',))
            self.assertEqual(kwargs['timeout'], 10)
            self.assertEqual(kwargs['context'].verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(kwargs['context'].check_hostname)
            method,path,data,headers=connection.return_value.request.call_args.args
            body=json.loads(data); self.assertEqual((method,path),('POST','/chat/completions')); self.assertEqual(body['model'],'deepseek-flash')
            self.assertEqual(body['response_format'],{'type':'json_object'}); self.assertEqual(headers['Authorization'],'Bearer unit-test-only')
            self.assertNotIn('unit-test-only',str(body)); self.assertEqual(body['messages'][1]['content'][1]['image_url']['url'],'data:image/jpeg;base64,'+self.packet['image'])
            self.assertEqual(result,example(ctx))
            prompt=body['messages'][0]['content']
            self.assertEqual(prompt,server.planner_prompt(ctx['capture']['sample']['id']))
            self.assertNotIn(ctx['utterance'],prompt)
            self.assertEqual(json.loads(body['messages'][1]['content'][0]['text']),ctx)

    def test_rejects_malformed_model_data(self):
        ctx=self.packet['context']; stamp=ctx['capture']['sample']['id']
        for change in [dict(target_ref='missing'),dict(uncertain=True),dict(frame_id={**stamp,'frame':1}),dict(hazards=[{'ref':'o1','kind':'person','box':[0,0,.1,.9]}]),dict(observations=[{'ref':'o1','kind':'door','box':[.5,.2,.3,.4]}])]:
            with self.assertRaises(ValueError): server.validate_reply({**example(ctx),**change},stamp)

    def test_sign_contract_refs_and_capture_frame(self):
        ctx = self.packet['context']
        stamp = ctx['capture']['sample']['id']
        for name, valid, reply in contract_cases(ctx):
            with self.subTest(case=name):
                if valid:
                    self.assertEqual(server.validate_reply(reply, stamp), reply)
                else:
                    with self.assertRaises(ValueError):
                        server.validate_reply(reply, stamp)

    @patch('server.validate_image')
    def test_context_carries_typed_sign_evidence(self, _check_image):
        ctx = self.packet['context']
        feature = {'kind':'sign', 'confidence':0.7, 'box':[0,.1,.9,.4], 'sign':{'symbol':'clinic','text':'眼科','arrow':'↗'}}
        anchor = dict(feature, id=1, last_seen=3.5, position_seen_from={'x':0,'y':1.4,'z':0}, heading_seen_from=0)
        ctx.update(features=[feature], known=[anchor])
        self.assertEqual(server.validate_input(self.packet)[0]['known'][0]['sign'], feature['sign'])
        for section, value in [('features',[dict(feature,kind='door')]), ('known',[dict(anchor,label='a\nb')]),
                               ('known',[dict(anchor,sign={'symbol':'unknown','arrow':'→'})]),
                               ('known',[dict(anchor, target_ref='o1')]), ('known',[anchor,anchor]),
                               ('recent_hazards',[anchor]), ('sign_history',['目\u202e标']), ('features',[dict(feature,appearance=3)])]:
            with self.subTest(section=section), self.assertRaises(ValueError):
                server.validate_input(dict(self.packet, context=dict(ctx, **{section:value})))

    def test_root_selection_respects_default_and_user_trust(self):
        for roots, capath, custom, fallback in [(0,None,{},True), (4,None,{},False), (0,'/hashed',{},False),
                                               (0,None,{'SSL_CERT_FILE':'user.pem'},False), (0,None,{'SSL_CERT_DIR':'user'},False)]:
            with self.subTest(roots=roots,capath=capath,custom=custom), patch.dict('os.environ',custom,clear=True), \
                 patch('server.ssl.create_default_context') as factory, patch('server.ssl.get_default_verify_paths') as paths, \
                 patch('server.Path.is_file',return_value=True):
                context = factory.return_value
                context.cert_store_stats.return_value = {'x509_ca':roots}
                paths.return_value.capath = capath
                self.assertIs(server.provider_tls_context(), context)
                if fallback:
                    context.load_verify_locations.assert_called_once_with(cafile='/etc/ssl/cert.pem')
                else:
                    context.load_verify_locations.assert_not_called()

    def test_provider_faults_are_allowlisted_and_do_not_echo_upstream(self):
        ctx = self.packet['context']
        with patch('server.http.client.HTTPSConnection') as connection:
            transport = connection.return_value
            response = transport.getresponse.return_value
            response.reason = response.read.return_value = 'private upstream diagnostic'
            for status, expected in [(401,'upstream_auth'), (429,'upstream_rate_limit'), (400,'upstream_rejected'),
                                     (404,'upstream_rejected'), (502,'upstream_http'), (504,'upstream_timeout')]:
                response.status = status
                with self.subTest(status=status), self.assertRaises(server.UpstreamFailure) as caught:
                    server.provider(ctx,'fixture','unit-test-only')
                self.assertEqual(str(caught.exception), expected)
                response.read.assert_not_called()
            for error, expected in [(ssl.SSLCertVerificationError('private'),'upstream_tls'),
                                    (TimeoutError('private'),'upstream_timeout'), (OSError('private'),'upstream_transport')]:
                transport.request.side_effect = error
                with self.assertRaises(server.UpstreamFailure) as caught:
                    server.provider(ctx,'fixture','unit-test-only')
                self.assertEqual(str(caught.exception), expected)
            transport.request.side_effect = None
            response.status = 200
            for body in [b'private', b'{"choices":[]}', b'{"choices":[{}]}', b'{"choices":[{"finish_reason":"length"}]}',
                         b'{"choices":[{"finish_reason":"stop","message":{"content":"{\\"a\\":1,\\"a\\":2}"}}]}']:
                response.read.return_value = body
                with self.assertRaises(server.UpstreamFailure) as caught:
                    server.provider(ctx,'fixture','unit-test-only')
                self.assertEqual(str(caught.exception), 'upstream_schema')

    def test_blind_smoke_exposes_only_structural_results(self):
        ctx = self.packet['context']
        reply = example(ctx)
        reply.update(target_ref='PrivateClinic', speech_zh='诊室的名字在这里')
        reply['observations'] = [{'ref':'PrivateClinic', 'kind':'sign', 'box':[.1,.2,.4,.5],
                                  'sign':{'symbol':'clinic', 'text':'康复科', 'arrow':'↗'}}]
        class Relay:
            server_port = 1
            pair = 'test-only-token'
        with patch('smoke_sign.http.client.HTTPConnection') as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps(reply).encode()
            summary = smoke_sign.exchange(Relay, self.packet)
            _, path, body, headers = connection.return_value.request.call_args.args
            self.assertEqual(path, '/test-only-token/next')
            self.assertEqual(json.loads(body), self.packet)
            self.assertEqual(headers, {'Content-Type':'application/json'})
            self.assertEqual(summary['target_ref'], 'o1')
            self.assertEqual(summary['observations'][0], {'ref':'o1','kind':'sign','box':[.1,.2,.4,.5],
                                                          'sign':{'symbol':'clinic','arrow':'↗','text_chars':3}})
            for secret in ['PrivateClinic','康复科',reply['speech_zh'],ctx['capture']['sample']['id']['session'],Relay.pair]:
                self.assertNotIn(secret, json.dumps(summary,ensure_ascii=False))
            response.status = 502
            for error, expected in [('provider private details','relay_http'), ('upstream_tls','upstream_tls')]:
                response.read.return_value = json.dumps({'error':error,'note':'private diagnostics'}).encode()
                self.assertEqual(smoke_sign.exchange(Relay,self.packet), {'status':'error','error':expected})

    def test_photo_cli_requires_an_operator_path_and_redacts_failures(self):
        # Reject a non-JPEG before opening anything, including when --live was requested.
        path = Path('/private/path-with-answer/PRIVATE-ROOM.png')
        out = io.StringIO()
        with redirect_stdout(out), patch('smoke_sign.live',side_effect=AssertionError('unexpected relay')):
            self.assertEqual(smoke_sign.main(['--image',str(path),'--live']), 1)
        self.assertEqual(json.loads(out.getvalue()), {'status':'error','error':'invalid_photo'})

    @patch('server.validate_image')
    def test_full_http_exchange_backpressure_and_sanitized_failures(self, _check_image):
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
                self.assertEqual(call(path),(502,{'error':'upstream_schema'}))
            finally:gate.set();srv.shutdown();worker.join(2)

if __name__=='__main__': unittest.main()
