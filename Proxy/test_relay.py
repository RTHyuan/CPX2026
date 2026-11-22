import base64
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
                {'arrow':'←'}, {'symbol':'unknown','text':'←','arrow':'←'},
                {'symbol':'exit','arrow':'left'}, {'symbol':'exit','arrow':'➡'},
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
    for action, speech in [('wait','可以慢慢转动手机，看看周围。'), ('rescan','请慢慢转动手机，补扫周围。')]:
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

    def test_legacy_reply_drops_only_standalone_arrow_meaning(self):
        for arrow in server.SIGN_ARROWS:
            reply = example(self.packet['context'])
            reply['observations'][0].update(kind='sign', sign={'symbol':'unknown', 'arrow':arrow})
            expected = copy.deepcopy(reply)
            del expected['observations'][0]['sign']
            with self.subTest(arrow=arrow):
                self.assertEqual(server.validate_reply(reply, reply['frame_id']), expected)
                self.assertEqual(reply['observations'][0]['sign'], {'symbol':'unknown', 'arrow':arrow})

    def test_legacy_reply_replaces_free_or_movement_speech_with_observation_prompt(self):
        for action, prompt in [('wait','可以慢慢转动手机，看看周围。'), ('rescan','请慢慢转动手机，补扫周围。'),
                               ('target_waypoint','请观察选定目标。'), ('verify_destination','转动手机，看看目的地的标识。')]:
            for wording in ['前方可见目的地标识，请转动手机核对。', '已经安全，向前走十米。', '请先站定。']:
                reply = example(self.packet['context'])
                reply.update(action=action, speech_zh=wording)
                if action in {'wait','rescan'}:
                    reply['target_ref'] = None
                with self.subTest(action=action, wording=wording):
                    result = server.validate_reply(reply, reply['frame_id'])
                    self.assertEqual(result['speech_zh'], prompt)
                    self.assertEqual(result['observations'], reply['observations'])
                    self.assertEqual(reply['speech_zh'], wording)

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

class TaskPlannerTests(unittest.TestCase):
    # Request bytes are a real, full-size CC0 door photo. Poses, boxes, room interpretation,
    # and model responses are controlled protocol fixtures; this is not semantic detection.
    @classmethod
    def setUpClass(cls):
        cls.photo = (Path(__file__).resolve().parents[1] / 'App/Resources/Practice/route-door.jpg').read_bytes()
        cls.width, cls.height = server.jpeg_size(cls.photo)
        cls.encoded = base64.b64encode(cls.photo).decode()

    def setUp(self):
        ctx = smoke_sign.make_context(self.width, self.height, str(uuid.uuid4()))
        ctx.update(utterance='带我去厕所', destination='洗手间')
        current = ctx['capture']['sample']['id']
        old = copy.deepcopy(ctx['capture']); old['sample']['id']['frame'] -= 4; old['sample']['time'] -= 1
        self.ctx, self.current, self.old = ctx, current, old['sample']['id']
        self.packet = {'context':ctx, 'image':self.encoded, 'version':2, 'execution_state':'observing',
                       'planning':{'scene':'room','task':'find_exit','version':2,'requires_exit':True},
                       'historical_frames':[{'pose':old, 'width':self.width, 'height':self.height, 'image':self.encoded}]}
        self.reply = dict(example(ctx), plan={'scene':'room','scene_uncertain':False,'task':'approach_aisle',
                                              'reason':'座椅挡住了门前，先核对侧过道入口。','completion':'aisle_reached'})
        self.reply['observations'][0]['source_frame'] = self.old
        self.reply['hazards'] = [{'ref':'seat','kind':'chair','box':[.4,.5,.7,.85],'source_frame':current}]
        self.sources = {current['frame'], self.old['frame']}

    def restroom_photo_reply(self):
        # Equivalent to the actual photo-61 model reply. The independently boxed arrow
        # must not prevent the restroom pictograms and corridor layout from being used.
        def item(ref, kind, coordinates, meaning=None):
            result = {'source_frame':dict(self.current), 'ref':ref, 'kind':kind, 'box':coordinates}
            if meaning is not None:
                result['sign'] = meaning
            return result
        return {'frame_id':dict(self.current), 'observations':[
                    item('ceiling_sign_restroom', 'sign', [0,.34,.34,.405], {'symbol':'restroom'}),
                    item('ceiling_sign_elevator', 'sign', [.19,.35,.3,.405], {'symbol':'elevator'}),
                    item('ceiling_sign_forward', 'sign', [.26,.35,.33,.405], {'symbol':'unknown','arrow':'↑'}),
                    item('wall_sign_restroom', 'sign', [.5,.425,.575,.465], {'symbol':'restroom'}),
                    item('corridor_open', 'aisle_entrance', [0,.45,.42,.66])],
                'hazards':[], 'action':'verify_destination', 'target_ref':'ceiling_sign_restroom',
                'speech_zh':'转动手机，看看目的地的标识。', 'uncertain':False,
                'plan':{'scene':'public_corridor', 'scene_uncertain':False, 'task':'verify_destination',
                        'reason':'天花板悬挂牌上有无障碍卫生间图标，前方通道延伸，可据此核对卫生间方向。',
                        'completion':'destination_verified',
                        'layout':{'kind':'corridor_layout','box':[0,.4,1,.7],'source_frame':dict(self.current)}}}

    def test_photo_reply_preserves_restroom_and_corridor_with_a_standalone_arrow(self):
        for arrow in server.SIGN_ARROWS:
            reply = self.restroom_photo_reply()
            reply['observations'][2]['sign']['arrow'] = arrow
            expected = copy.deepcopy(reply)
            del expected['observations'][2]['sign']
            with self.subTest(arrow=arrow):
                result = server.validate_reply(reply, self.current, self.sources)
                self.assertEqual(result, expected)
                self.assertEqual(result['observations'][0]['sign'], {'symbol':'restroom'})
                self.assertEqual(result['observations'][3]['sign'], {'symbol':'restroom'})
                self.assertEqual(reply['observations'][2]['sign'], {'symbol':'unknown','arrow':arrow})

    def test_standalone_arrow_does_not_relax_reply_geometry_frames_or_other_meanings(self):
        bad = [lambda r:r['observations'][2].update(kind='door'),
               lambda r:r['observations'][2].update(box=[.4,.2,.1,.5]),
               lambda r:r['observations'][2].update(ref='1arrow'),
               lambda r:r['observations'][2]['source_frame'].update(frame=99),
               lambda r:r['plan']['layout']['source_frame'].update(world=3),
               lambda r:r['plan'].update(task='walk_forward')]
        for meaning in [{'symbol':'unknown'}, {'symbol':'unknown','arrow':None},
                        {'symbol':'unknown','arrow':'left'}, {'symbol':'unknown','arrow':'➡'},
                        {'symbol':'unknown','arrow':[]}, {'symbol':'unknown','arrow':'↑','text':None},
                        {'symbol':'unknown','arrow':'↑','extra':True},
                        {'symbol':'unknown','arrow':'↑','text':'↑'}]:
            bad.append(lambda r, meaning=meaning:r['observations'][2].update(sign=meaning))
        for edit in bad:
            reply = copy.deepcopy(self.restroom_photo_reply())
            edit(reply)
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                server.validate_reply(reply, self.current, self.sources)

    def test_input_context_still_rejects_standalone_arrow_meaning(self):
        packet = copy.deepcopy(self.packet)
        packet['context']['features'] = [{'kind':'sign', 'box':[.26,.35,.33,.405], 'confidence':.8,
                                          'sign':{'symbol':'unknown','arrow':'↑'}}]
        with self.assertRaises(ValueError):
            server.validate_input(packet)

    def directional_restroom_photo_reply(self):
        # Equivalent to the second actual photo-61 reply: a directional board, a
        # separate wall pictogram and one independently boxed current passage.
        reply = self.restroom_photo_reply()
        reply['observations'] = [
            {'source_frame':dict(self.current),'ref':'ceiling_board_restroom','kind':'sign','box':[.06,.34,.3,.4],
             'sign':{'symbol':'restroom','arrow':'↑'}},
            {'source_frame':dict(self.current),'ref':'wall_restroom_sign','kind':'sign','box':[.51,.42,.58,.46],
             'sign':{'symbol':'restroom'}},
            {'source_frame':dict(self.current),'ref':'corridor_forward','kind':'junction','box':[0,.4,.35,.65]}]
        reply.update(action='rescan', target_ref=None,
                     speech_zh='天花导向牌有洗手间图标并指向前方，请慢慢转动手机再补扫确认。')
        reply['plan'] = {'scene':'public_corridor','scene_uncertain':False,'task':'find_signs',
                         'reason':'天花悬挂导向牌含男女洗手间图标及向上箭头，指示沿走廊前方前往；墙面亦有洗手间标志，可继续寻找对应入口。',
                         'completion':'sign_identified'}
        return reply

    def test_second_photo_reply_keeps_directional_sign_and_derives_unique_current_passage_layout(self):
        for kind in ['junction','aisle_entrance']:
            reply = self.directional_restroom_photo_reply()
            reply['observations'][2]['kind'] = kind
            with self.subTest(kind=kind):
                result = server.validate_reply(reply, self.current, self.sources)
                self.assertEqual(result['speech_zh'], '请慢慢转动手机，补扫周围。')
                self.assertEqual(result['action'], 'rescan')
                self.assertIsNone(result['target_ref'])
                self.assertEqual(result['observations'], reply['observations'])
                self.assertEqual(result['plan'], dict(reply['plan'], layout={
                    'kind':'corridor_layout','source_frame':self.current,'box':[0,.4,.35,.65]}))
                self.assertEqual(result['observations'][0]['sign'], {'symbol':'restroom','arrow':'↑'})
                self.assertNotIn('layout', reply['plan'])

    def mixed_legend_restroom_photo_reply(self):
        # Equivalent to the third actual photo-61 reply. The entire mixed legend is
        # untrusted semantic evidence; the separately boxed wall pictogram remains useful.
        reply = self.directional_restroom_photo_reply()
        reply['observations'] = [
            {'source_frame':dict(self.current),'ref':'hall_sign_left','kind':'sign','box':[0,.337,.348,.402],
             'sign':{'symbol':'restroom','text':'洗手间 电梯 | 直行 ↑','arrow':'↑'}},
            {'source_frame':dict(self.current),'ref':'wall_restroom_icon','kind':'sign','box':[.508,.423,.565,.449],
             'sign':{'symbol':'restroom'}},
            {'source_frame':dict(self.current),'ref':'corridor_open','kind':'aisle_entrance','box':[0,.4,.3,.6]}]
        reply.update(action='wait', speech_zh='可以慢慢转动手机，看看周围。')
        reply['plan']['reason'] = '左上方悬挂导向牌含洗手间图标与墙面上洗手间图标，均指向同一通道方向，可据此继续引导。'
        return reply

    def test_third_photo_reply_discards_mixed_legend_meaning_and_preserves_other_evidence(self):
        reply = self.mixed_legend_restroom_photo_reply()
        result = server.validate_reply(reply, self.current, self.sources)
        self.assertEqual(result['action'], 'wait')
        self.assertIsNone(result['target_ref'])
        self.assertEqual(result['speech_zh'], reply['speech_zh'])
        self.assertEqual(result['observations'][0], {key:value for key,value in reply['observations'][0].items() if key != 'sign'})
        self.assertEqual(result['observations'][1:], reply['observations'][1:])
        self.assertEqual(result['plan'], dict(reply['plan'], layout={
            'kind':'corridor_layout','source_frame':self.current,'box':[0,.4,.3,.6]}))
        self.assertIn('sign', reply['observations'][0])

    def test_mixed_legend_reply_drops_all_sign_semantics_for_eight_arrow_glyphs(self):
        for version in [1, 2]:
            for symbol in ['restroom', 'unknown', 'directory']:
                for arrow in server.SIGN_ARROWS:
                    reply = self.mixed_legend_restroom_photo_reply()
                    reply['observations'][0]['sign'] = {'symbol':symbol, 'text':'洗手间 电梯 ' + arrow, 'arrow':arrow}
                    sources = self.sources if version == 2 else None
                    if version == 1:
                        del reply['plan']
                        for item in reply['observations']:
                            del item['source_frame']
                    with self.subTest(version=version, symbol=symbol, arrow=arrow):
                        result = server.validate_reply(reply, self.current, sources)
                        self.assertNotIn('sign', result['observations'][0])
                        self.assertEqual(result['observations'][1]['sign'], {'symbol':'restroom'})
        reply = self.mixed_legend_restroom_photo_reply()
        reply['observations'][0]['sign'] = {'symbol':'directory', 'text':'书屋 ←→↑↓↖↗↙↘'}
        self.assertNotIn('sign', server.validate_reply(reply, self.current, self.sources)['observations'][0])

    def test_mixed_legend_compatibility_still_rejects_bad_typed_arrows_and_structure(self):
        for meaning in [
            {'symbol':'restroom','text':'洗手间 ↑','arrow':'forward'},
            {'symbol':'restroom','text':'洗手间 ↑','arrow':'➡'},
            {'symbol':'restroom','text':'洗手间 ↑','arrow':[]},
            {'symbol':'restroom','text':'洗手间 ↑','arrow':5},
            {'symbol':'restroom','text':'洗手间 ↑','arrow':'↑','extra':1},
            {'symbol':'restroom','text':'↑','arrow':'↑'},
            {'symbol':'unknown','text':'↑↓ ←','arrow':'↑'},
            {'symbol':'restroom','text':'A' * 48 + '↑','arrow':'↑'},
            {'symbol':'restroom','text':'洗手间\n↑','arrow':'↑'},
            {'symbol':'restroom','text':'洗手间\u202e↑','arrow':'↑'},
            {'symbol':'invalid','text':'洗手间 ↑','arrow':'↑'}]:
            reply = self.mixed_legend_restroom_photo_reply()
            reply['observations'][0]['sign'] = meaning
            with self.subTest(meaning=meaning), self.assertRaises(ValueError):
                server.validate_reply(reply, self.current, self.sources)

    def test_input_context_still_rejects_text_containing_arrow_glyphs(self):
        packet = copy.deepcopy(self.packet)
        packet['context']['features'] = [{'kind':'sign', 'box':[0,.337,.348,.402], 'confidence':.8,
                                          'sign':{'symbol':'restroom','text':'洗手间 电梯 | 直行 ↑','arrow':'↑'}}]
        with self.assertRaises(ValueError):
            server.validate_input(packet)

    def test_missing_corridor_layout_requires_one_valid_current_passage(self):
        edits = [lambda r:r['observations'].pop(),
                 lambda r:r['observations'][2].update(kind='sign'),
                 lambda r:r['observations'][2].update(source_frame=self.old),
                 lambda r:r['observations'][2].update(box=[.5,.4,.35,.65]),
                 lambda r:r['observations'][2]['source_frame'].update(frame=999),
                 lambda r:r['observations'].append(dict(r['observations'][2], ref='other_corridor')),
                 lambda r:r['plan'].update(layout={'kind':'other','source_frame':self.current,'box':[0,.4,.35,.65]}),
                 lambda r:r['plan'].update(layout=None)]
        for edit in edits:
            reply = self.directional_restroom_photo_reply()
            edit(reply)
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                server.validate_reply(reply, self.current, self.sources)

    def test_v2_free_speech_is_sanitized_but_invalid_text_is_still_rejected(self):
        for action, prompt in [('wait','可以慢慢转动手机，看看周围。'), ('rescan','请慢慢转动手机，补扫周围。'),
                               ('target_waypoint','请观察选定目标。'), ('verify_destination','转动手机，看看目的地的标识。')]:
            reply = self.restroom_photo_reply()
            reply.update(action=action, speech_zh='通道安全，请一直向前走。')
            if action in {'wait','rescan'}:
                reply['target_ref'] = None
            with self.subTest(action=action):
                result = server.validate_reply(reply, self.current, self.sources)
                self.assertEqual(result['speech_zh'], prompt)
                self.assertEqual(result['plan'], reply['plan'])
                self.assertEqual(result['action'], action)
        for speech in [None, 7, '', 'A' * 65, '再扫\n一下', '前\u202e方']:
            reply = self.directional_restroom_photo_reply()
            reply['speech_zh'] = speech
            with self.subTest(speech=speech), self.assertRaises(ValueError):
                server.validate_reply(reply, self.current, self.sources)

    def test_shared_phone_template_example_tracks_the_current_frame_and_all_allowed_tasks(self):
        prompt = server.task_planner_prompt(self.current)
        example = json.loads(prompt.splitlines()[-1])
        self.assertEqual(server.validate_reply(example, self.current, {self.current['frame']}), example)
        later = dict(self.current, frame=self.current['frame'] + 7)
        self.assertEqual(json.loads(server.task_planner_prompt(later).splitlines()[-1])['frame_id'], later)
        for task, completion in server.COMPLETIONS.items():
            self.assertIn(task, prompt)
            self.assertIn(completion, prompt)
        self.assertNotIn('__PATHSENSE_CAPTURE_ID__', prompt)

    def test_full_native_images_are_bound_to_distinct_earlier_captures(self):
        self.assertGreater(max(self.width,self.height), 1024)
        self.assertEqual(server.validate_input(self.packet), (self.ctx,self.current))
        for edit in [lambda p:p['historical_frames'].append(p['historical_frames'][0]),
                     lambda p:p['historical_frames'][0]['pose']['sample']['id'].update(world=5),
                     lambda p:p['historical_frames'][0]['pose']['sample']['id'].update(frame=self.current['frame']),
                     lambda p:p['historical_frames'][0]['pose']['sample'].update(time=self.ctx['capture']['sample']['time']),
                     lambda p:p['historical_frames'][0].update(width=self.width-1),
                     lambda p:p['context'].update(image_height=self.height//2),
                     lambda p:p['context']['capture']['sample'].update(exif=6),
                     lambda p:p.update(planning={'scene':'room','task':'walk','requires_exit':True,'version':4})]:
            packet = copy.deepcopy(self.packet); edit(packet)
            with self.subTest(edit=edit), self.assertRaises(ValueError): server.validate_input(packet)
        packet = copy.deepcopy(self.packet); packet['historical_frames'] = []
        self.assertEqual(server.validate_input(packet), (self.ctx,self.current))

    def test_received_plan_cannot_claim_safety_change_geometry_or_reassign_history(self):
        self.assertEqual(server.validate_reply(self.reply, self.current, self.sources), self.reply)
        def changed(edit):
            reply = copy.deepcopy(self.reply); edit(reply); return reply
        bad = [lambda r:r.pop('plan'), lambda r:r.update(action='walk_forward'),
               lambda r:r['plan'].update(completion='destination_verified'), lambda r:r['plan'].update(scene='public_corridor'),
               lambda r:r['plan'].update(safe_to_walk=True), lambda r:r['observations'][0].update(point=[0,0,-2]),
               lambda r:r['observations'][0]['source_frame'].update(frame=99), lambda r:r['observations'][0]['source_frame'].update(world=6),
               lambda r:r['observations'][0]['source_frame'].update(frame=True), lambda r:r['observations'][0].pop('source_frame'),
               lambda r:r['hazards'][0].update(source_frame=self.old), lambda r:r.update(hazards=[]),
               lambda r:r['plan'].update(layout={'kind':'room_layout','box':[.2,.2,.8,.8],'source_frame':dict(self.current,frame=300)})]
        for edit in bad:
            with self.subTest(edit=edit), self.assertRaises(ValueError): server.validate_reply(changed(edit), self.current, self.sources)
        empty_room = changed(lambda r:r.update(hazards=[]))
        empty_room['plan']['layout'] = {'kind':'room_layout','box':[.2,.2,.8,.8],'source_frame':self.current}
        self.assertEqual(server.validate_reply(empty_room,self.current,self.sources),empty_room)
        with self.assertRaises(ValueError): server.validate_reply(self.reply, self.current)

    def test_request_reaches_provider_with_both_images_and_original_capture_identities(self):
        with patch('server.http.client.HTTPSConnection') as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps({'choices':[{'finish_reason':'stop','message':{'content':json.dumps(self.reply)}}]}).encode()
            result = server.provider(self.ctx, self.encoded, 'unit-test-only', planning=self.packet['planning'],
                                     execution_state=self.packet['execution_state'], historical_frames=self.packet['historical_frames'])
            payload = json.loads(connection.return_value.request.call_args.args[2]); messages = payload['messages']
            content = messages[1]['content']
            self.assertEqual(json.loads(content[0]['text'])['planning']['task'],'find_exit')
            self.assertEqual(json.loads(content[0]['text'])['execution_state'],'observing')
            self.assertEqual(json.loads(content[1]['text'])['frame_id'],self.current)
            self.assertEqual(json.loads(content[3]['text'])['frame_id'],self.old)
            self.assertEqual(json.loads(content[3]['text'])['pose'],self.packet['historical_frames'][0]['pose'])
            for i in (2,4): self.assertEqual(base64.b64decode(content[i]['image_url']['url'].split(',',1)[1]),self.photo)
            self.assertNotIn(self.ctx['utterance'], messages[0]['content'])
            self.assertEqual(server.validate_reply(result,self.current,self.sources),self.reply)

    def test_v2_http_validates_response_against_images_actually_received(self):
        def planner(ctx, image, key, *, planning, execution_state, historical_frames):
            self.assertEqual(image, self.encoded); self.assertEqual(planning['version'],2)
            self.assertEqual(execution_state,'observing'); self.assertEqual(ctx['utterance'],'带我去厕所')
            return self.reply
        with server.Server(('127.0.0.1',0),'test-only',planner) as srv:
            t = threading.Thread(target=srv.serve_forever,daemon=True); t.start()
            try:
                def exchange(packet):
                    conn = http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=5)
                    try:
                        conn.request('POST','/'+srv.pair+'/next',json.dumps(packet),{'Content-Type':'application/json'})
                        res=conn.getresponse(); return res.status,json.loads(res.read())
                    finally: conn.close()
                self.assertEqual(exchange(self.packet),(200,self.reply))
                # Same response is now invalid: the historical source photo was not uploaded.
                self.assertEqual(exchange(dict(self.packet,historical_frames=[])),(502,{'error':'upstream_schema'}))
            finally: srv.shutdown(); t.join(2)

if __name__=='__main__': unittest.main()
