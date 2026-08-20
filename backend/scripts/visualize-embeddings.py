#!/usr/bin/env python3
"""
visualize-embeddings.py

Trực quan hóa các vector trong user_embedding_chunks.
  1. Vẽ PCA + t-SNE 2D (PNG), tô màu theo cụm sở thích/kỹ năng.
  2. Xuất 2 file TSV cho TensorFlow Embedding Projector (projector.tensorflow.org):
       projector_vectors.tsv   — embedding (tab-separated floats, no header)
       projector_metadata.tsv  — cluster / source_type / mode / name / terms (có header)

Yêu cầu: sklearn, matplotlib, numpy; DB chạy trong Docker container (mặc định
connectsphere_db). Đọc DB_NAME/DB_USER từ backend/.env.

Chạy:  python3 scripts/visualize-embeddings.py
       DB_CONTAINER=my_db python3 scripts/visualize-embeddings.py   # đổi container
"""
import os, subprocess, sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import numpy as np
import matplotlib.pyplot as plt
from sklearn.decomposition import PCA
from sklearn.manifold import TSNE

BACKEND_DIR = Path(__file__).resolve().parent.parent
OUT_DIR = BACKEND_DIR / 'scripts' / 'embedding-viz'
OUT_DIR.mkdir(exist_ok=True)


def load_env(path):
    """Đọc key=value từ .env (đơn giản, bỏ comment/blank)."""
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    return env


# Cụm coarse suy từ interest/skill — khớp thiết kế seed, tự về 'other' nếu không match.
EXPORT_SQL = """
SELECT
  CASE
    WHEN EXISTS(SELECT 1 FROM user_interests ui WHERE ui.user_id=u.id AND ui.interest='Anime') THEN 'anime'
    WHEN EXISTS(SELECT 1 FROM user_interests ui WHERE ui.user_id=u.id AND ui.interest='Coffee') THEN 'coffee'
    WHEN EXISTS(SELECT 1 FROM user_interests ui WHERE ui.user_id=u.id AND ui.interest='Football') THEN 'sports'
    WHEN EXISTS(SELECT 1 FROM user_interests ui WHERE ui.user_id=u.id AND ui.interest IN ('Music','K-drama')) THEN 'music'
    WHEN EXISTS(SELECT 1 FROM user_skills us WHERE us.user_id=u.id AND us.skill='React') THEN 'react'
    WHEN EXISTS(SELECT 1 FROM user_skills us WHERE us.user_id=u.id AND us.skill IN ('Python','Machine Learning')) THEN 'data'
    WHEN EXISTS(SELECT 1 FROM user_skills us WHERE us.user_id=u.id AND us.skill IN ('AWS','Docker')) THEN 'cloud'
    ELSE 'other'
  END AS cluster,
  c.source_type,
  u.default_mode,
  u.display_name,
  COALESCE(
    (SELECT string_agg(x, ', ') FROM (
       SELECT ui.interest x FROM user_interests ui WHERE ui.user_id=u.id
       UNION ALL SELECT us.skill FROM user_skills us WHERE us.user_id=u.id
     ) t), '') AS terms,
  c.embedding::text
FROM user_embedding_chunks c
JOIN users u ON u.id = c.user_id
ORDER BY cluster, c.source_type;
"""

COLORS = {
    'anime': '#E8590C', 'coffee': '#845EF7', 'sports': '#2F9E44', 'music': '#E64980',
    'react': '#1971C2', 'data': '#0CA678', 'cloud': '#F08C00', 'other': '#adb5bd',
}
ORDER = ['anime', 'coffee', 'sports', 'music', 'react', 'data', 'cloud', 'other']


def fetch_rows():
    env = load_env(BACKEND_DIR / '.env')
    container = os.environ.get('DB_CONTAINER', 'connectsphere_db')
    db = env.get('DB_NAME', 'connectsphere')
    user = env.get('DB_USER', 'connectsphere_user')
    cmd = ['docker', 'exec', container, 'psql', '-U', user, '-d', db,
           '-A', '-F', '\t', '-t', '-c', EXPORT_SQL]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'psql failed:\n{out.stderr}')
    rows = []
    for line in out.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) < 6:
            continue
        cluster, stype, mode, name, terms, vec = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
        rows.append((cluster, stype, mode, name, terms,
                     [float(x) for x in vec.strip('[]').split(',')]))
    return rows


def write_projector_tsv(rows):
    """2 file TSV cho TensorFlow Embedding Projector."""
    vpath = OUT_DIR / 'projector_vectors.tsv'
    mpath = OUT_DIR / 'projector_metadata.tsv'
    with vpath.open('w') as vf, mpath.open('w') as mf:
        mf.write('cluster\tsource_type\tmode\tname\tterms\n')  # header bắt buộc khi nhiều cột
        for cluster, stype, mode, name, terms, vec in rows:
            vf.write('\t'.join(f'{x:.6f}' for x in vec) + '\n')
            safe = lambda s: s.replace('\t', ' ').replace('\n', ' ')
            mf.write(f'{safe(cluster)}\t{safe(stype)}\t{safe(mode)}\t{safe(name)}\t{safe(terms)}\n')
    return vpath, mpath


def plot(rows):
    X = np.array([r[5] for r in rows])
    clusters = np.array([r[0] for r in rows])
    types = np.array([r[1] for r in rows])
    print(f'Loaded {X.shape[0]} vectors, dim {X.shape[1]}')

    pca2 = PCA(n_components=2).fit_transform(X)
    perp = min(15, max(5, X.shape[0] // 4))
    tsne2 = TSNE(n_components=2, perplexity=perp, init='pca', random_state=42).fit_transform(X)

    fig, axes = plt.subplots(1, 2, figsize=(15, 7))
    for ax, coords, title in [(axes[0], pca2, 'PCA (global variance)'),
                              (axes[1], tsne2, f't-SNE (local clusters, perplexity={perp})')]:
        for lab in ORDER:
            for typ, marker, size, alpha in [('user_profile', 'o', 110, 0.95), ('post', '.', 40, 0.55)]:
                m = (clusters == lab) & (types == typ)
                if m.any():
                    ax.scatter(coords[m, 0], coords[m, 1], c=COLORS[lab], marker=marker, s=size,
                               alpha=alpha, edgecolors='white', linewidths=0.4)
        ax.set_title(title, fontsize=13, weight='bold')
        ax.set_xticks([]); ax.set_yticks([])
        ax.spines[['top', 'right']].set_visible(False)

    handles = [plt.Line2D([0], [0], marker='o', color='w', markerfacecolor=COLORS[l],
                          markersize=10, label=l) for l in ORDER]
    fig.legend(handles=handles, loc='lower center', ncol=len(ORDER), frameon=False,
               fontsize=11, bbox_to_anchor=(0.5, -0.02))
    fig.suptitle(f'ConnectSphere embeddings — {X.shape[0]} chunks (profile ●  +  post ·) theo cụm',
                 fontsize=14, weight='bold')
    plt.tight_layout(rect=[0, 0.04, 1, 0.96])
    png = OUT_DIR / 'embeddings_2d.png'
    plt.savefig(png, dpi=130, bbox_inches='tight')
    return png


def main():
    rows = fetch_rows()
    if not rows:
        sys.exit('Không có chunk nào trong DB — hãy seed + build chunk trước.')
    png = plot(rows)
    vpath, mpath = write_projector_tsv(rows)
    print(f'\n✅ PNG:        {png}')
    print(f'✅ Projector:  {vpath}')
    print(f'              {mpath}')
    print('\nMở https://projector.tensorflow.org → nút "Load" (bên trái) →')
    print('  chọn projector_vectors.tsv cho "vectors", projector_metadata.tsv cho "metadata".')
    print('  Rồi chọn t-SNE/UMAP/PCA, tô màu theo cột "cluster" hoặc "mode".')


if __name__ == '__main__':
    main()
