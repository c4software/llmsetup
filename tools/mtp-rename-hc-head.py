#!/usr/bin/env python3
# =============================================================================
# mtp-rename-hc-head.py — rend un sidecar MTP Qwen3.8-Flash-Next chargeable par
# le fork halo-box/strix-llama.cpp.
#
# Usage :
#   PYTHONPATH=$HOME/llm/strix-llama.cpp/gguf-py \
#     python3 tools/mtp-rename-hc-head.py <entrée.gguf> <sortie.gguf>
#   (appelé aussi par ./setup-llm.sh --setup, cf. _derive dans lib/common.sh)
#
# Pourquoi : deux conventions de nommage pour le MÊME tenseur. Le mixeur final
# des hyper-connexions de la tête MTP est rangé par unsloth (convention de la PR
# mainline ggml-org/llama.cpp #28243) sous les noms de bloc
#   blk.<n>.nextn.hc_head_{norm,down,up}.weight
# alors que le graphe MTP qwen4exp du fork (src/models/qwen4exp.cpp, graph_mtp)
# les lit sous les noms de niveau modèle
#   output_hc_{norm,down,up}.weight
# Un sidecar unsloth chargé tel quel sur le fork échoue donc sur
#   check_tensor_dims: tensor 'output_hc_norm.weight' not found
# et le modèle entier ne charge plus. Mêmes formes (10240 ; 10240x320 ;
# 320x10240) et mêmes types (F32, Q8_0, Q8_0) des deux côtés : un renommage des
# trois tenseurs suffit, aucune conversion de données.
#
# SPÉCIFIQUE AU FORK. Un moteur mainline portant #28243 lira le sidecar unsloth
# tel quel : ce script n'a alors plus lieu d'être (et sa sortie, elle, ne serait
# plus lisible par ce moteur-là).
#
# Le gguf-py utilisé doit être celui du fork (PYTHONPATH), pas un gguf installé
# par pip : c'est lui qui connaît l'arch qwen4exp.
# Dépendances : gguf-py (numpy) ; tqdm seulement si installé (barre de
# progression), sinon le script se tait — pas de dépendance nouvelle imposée.
# =============================================================================
import sys, re
import gguf

try:
    from tqdm import tqdm
except ImportError:  # tqdm optionnel : repli silencieux
    def tqdm(*_a, **_kw):
        class _Muet:
            def update(self, _n): pass
        return _Muet()

src, dst = sys.argv[1], sys.argv[2]
reader = gguf.GGUFReader(src)
arch = reader.fields[gguf.Keys.General.ARCHITECTURE].contents()
writer = gguf.GGUFWriter(dst, arch=arch, endianess=reader.endianess)

for field in reader.fields.values():
    if field.name == gguf.Keys.General.ARCHITECTURE or field.name.startswith('GGUF.'):
        continue
    val_type = field.types[0]
    sub_type = field.types[-1] if val_type == gguf.GGUFValueType.ARRAY else None
    writer.add_key_value(field.name, field.contents(), val_type, sub_type=sub_type)

ren = re.compile(r'^blk\.\d+\.nextn\.hc_head_(norm|down|up)\.weight$')
names = {}
for t in reader.tensors:
    m = ren.match(t.name)
    names[t.name] = f'output_hc_{m.group(1)}.weight' if m else t.name
    writer.add_tensor_info(names[t.name], t.data.shape, t.data.dtype, t.data.nbytes, t.tensor_type)
renamed = [(k, v) for k, v in names.items() if k != v]
assert len(renamed) == 3, renamed
for k, v in renamed:
    print(f'{k} -> {v}')

writer.write_header_to_file()
writer.write_kv_data_to_file()
writer.write_ti_data_to_file()
bar = tqdm(desc='Writing', total=sum(t.n_bytes for t in reader.tensors), unit='byte', unit_scale=True)
for t in reader.tensors:
    writer.write_tensor_data(t.data, tensor_endianess=reader.endianess)
    bar.update(t.n_bytes)
writer.close()
print('OK', dst)
