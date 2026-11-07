"""Routing parity and integrity of contributor experiments, not clinical validation."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools/benchmark'))
import saved_representation as rep


class SavedRepresentationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.source = self.root/'source'
        (self.source/'objects').mkdir(parents=True)
        self.context = dict(zip(rep.CONTEXT, ['2.0.0','pub','release','source','profile','1','a'*64,'scope']))
        self.leaves = []
        for value in ['1','3']:
            doc = dict(self.context,kind='concept_catalogue',entries=[dict(concept_tag=dict(kind='id',value=value),label=None,label_state='unavailable')])
            self.leaves.append(self.emit(doc,'1'))
        self.children = [dict(lower_key='I1000001:'+v,upper_key='I1000001:'+v,object=d) for v,d in zip(['1','3'],self.leaves)]
        self.tree = self.emit(dict(self.context,kind='index',index_kind='concept_catalogue',children=self.children),'2')
        (self.source/'routing.json').write_bytes(rep.canonical(dict(scope='routing_fixture_not_an_approved_publication',context=self.context,trees=dict(concept_catalogue=self.tree))))
        self.pin = rep.origin(self.source)
        self.flat = self.root/'flat'; self.flat.mkdir(); rep.copy_artifact(self.source,self.flat/'artifact')
        self.manifest_sha = rep.build_flat(self.flat,self.pin)

    def emit(self, doc, rows):
        raw = rep.canonical(doc); sha = rep.digest(raw)
        (self.source/'objects'/(sha+'.json')).write_bytes(raw)
        return dict(sha256=sha,bytes=str(len(raw)),kind=doc['kind'],rows=rows)

    def test_exact_partition_parity_including_absence(self):
        tree = rep.Tree(self.source,self.pin); flat = rep.Flat(self.flat,self.pin,self.manifest_sha)
        self.addCleanup(flat.close)
        for value in ['0','1','2','3','4']:
            self.assertEqual(tree.lookup('concept_catalogue','I1000001:'+value),flat.lookup('concept_catalogue','I1000001:'+value))
        self.assertEqual(flat.lookup('concept_catalogue','I1000001:1')[0],self.leaves[0]['sha256'])
        for reader in [tree,flat]:
            with self.assertRaises(ValueError):reader.lookup('unknown','x')
            with self.assertRaises(ValueError):reader.lookup('concept_catalogue','x'*1025)

    def test_page_corruption_and_cross_context_refused(self):
        readers = [rep.Tree(self.source,self.pin),rep.Flat(self.flat,self.pin,self.manifest_sha)]
        self.addCleanup(readers[1].close)
        for directory,reader in zip([self.source,self.flat/'artifact'],readers):
            (directory/'objects'/(self.leaves[0]['sha256']+'.json')).write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError,'integrity'):reader.lookup('concept_catalogue','I1000001:1')
        pin = dict(self.pin,context=dict(self.context,source_id='other-source'))
        with self.assertRaisesRegex(ValueError,'context'):rep.Tree(self.source,pin).lookup('concept_catalogue','I1000001:1')
        with self.assertRaisesRegex(ValueError,'context'):rep.Flat(self.flat,pin,self.manifest_sha)

    def test_index_seal_and_private_spool_cleanup(self):
        flat = rep.Flat(self.flat,self.pin,self.manifest_sha); folder = Path(flat.temp.name)
        self.assertEqual(folder.stat().st_mode & 0o777,0o700)
        (self.flat/'routes.sqlite').write_bytes(b'changed-after-open')
        self.assertEqual(flat.lookup('concept_catalogue','I1000001:1')[0],self.leaves[0]['sha256'])
        flat.close(); self.assertFalse(folder.exists())
        with self.assertRaises(ValueError):rep.Flat(self.flat,self.pin,self.manifest_sha)

    def test_changed_index_same_size_rejected_and_spool_removed(self):
        original = (self.flat/'routes.sqlite').read_bytes()
        (self.flat/'routes.sqlite').write_bytes(original[:-1]+bytes([original[-1]^1]))
        folders = []; factory = tempfile.TemporaryDirectory
        def record(*args,**kwargs):
            value = factory(*args,**kwargs); folders.append(Path(value.name)); return value
        with patch.object(rep.tempfile,'TemporaryDirectory',side_effect=record):
            with self.assertRaisesRegex(ValueError,'integrity'):rep.Flat(self.flat,self.pin,self.manifest_sha)
        self.assertTrue(folders); self.assertTrue(all(not f.exists() for f in folders))

    def test_manifest_descriptor_and_json_fail_closed(self):
        path = self.flat/'flat.json'; path.write_bytes(path.read_bytes()+b' ')
        with self.assertRaisesRegex(ValueError,'manifest integrity'):rep.Flat(self.flat,self.pin,self.manifest_sha)
        pages = rep.Pages(self.source,self.context)
        for descriptor in [dict(self.leaves[0],bytes='1e3'),dict(self.leaves[0],rows='01'),dict(self.leaves[0],sha256='../bad')]:
            with self.assertRaises(ValueError):pages.read(descriptor)
        with self.assertRaises(ValueError):rep.decode(b'{"a":1,"a":1}\n')
        with self.assertRaises(ValueError):rep.Pages(self.source,{})

    def test_symlink_and_overlapping_ranges_rejected(self):
        path = self.source/'objects'/(self.leaves[0]['sha256']+'.json')
        moved = self.root/'moved'; path.rename(moved); path.symlink_to(moved)
        with self.assertRaises(ValueError):rep.Tree(self.source,self.pin).lookup('concept_catalogue','I1000001:1')
        children = [self.children[0],dict(self.children[1],lower_key=self.children[0]['upper_key'])]
        descriptor = self.emit(dict(self.context,kind='index',index_kind='concept_catalogue',children=children),'2')
        with self.assertRaisesRegex(ValueError,'ranges'):rep.Tree(self.source,dict(self.pin,trees=dict(concept_catalogue=descriptor))).lookup('concept_catalogue','I1000001:1')

    def test_depth_limit_and_raw_byte_copy(self):
        descriptor = self.leaves[0]
        for _ in range(9):
            descriptor = self.emit(dict(self.context,kind='index',index_kind='concept_catalogue',children=[dict(self.children[0],object=descriptor)]),'1')
        with self.assertRaisesRegex(ValueError,'depth'):rep.Tree(self.source,dict(self.pin,trees=dict(concept_catalogue=descriptor))).lookup('concept_catalogue','I1000001:1')
        for path in (self.flat/'artifact'/'objects').iterdir():
            self.assertEqual(path.read_bytes(),(self.source/'objects'/path.name).read_bytes())


if __name__ == '__main__':unittest.main()
