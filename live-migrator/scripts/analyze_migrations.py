#!/usr/bin/env python3
# ============================================================================
# analyze_migrations.py — Analyse des logs de migration et génération de courbes
#
# Usage :
#   python3 analyze_migrations.py <fichier_log> [--output-dir <dossier>]
#
# Entrée : /var/lib/live-migrator/migration_history.log
#          ou /var/log/live-migrator.log
#
# Sorties :
#   - migration_durations.png      : Durée de chaque migration
#   - migration_success_rate.png   : Taux de succès/échec
#   - migration_timeline.png       : Timeline des migrations
#   - migration_by_reason.png      : Répartition par raison
#   - migration_by_target.png      : Répartition par nœud cible
#   - metrics_over_time.png        : Métriques CPU/RAM/Temp au fil du temps
#   - rapport_migrations.txt       : Résumé statistique textuel
# ============================================================================

import re
import sys
import os
from datetime import datetime
from collections import Counter, defaultdict

# Essayer d'importer matplotlib, sinon donner les instructions
try:
    import matplotlib
    matplotlib.use('Agg')  # Backend non-interactif (pas besoin de display)
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False


def parse_history_log(filepath):
    """Parse le fichier migration_history.log"""
    migrations = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # Format : 2026-04-18 16:34:45 | VM=103 | rem | maintenance | 45s | OK
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 5:
                entry = {
                    'timestamp': parts[0],
                    'vm': parts[1].replace('VM=', '').strip(),
                    'target': parts[2].strip(),
                    'reason': parts[3].strip(),
                }
                # Durée et statut
                if len(parts) >= 6:
                    duration_str = parts[4].strip().replace('s', '')
                    try:
                        entry['duration'] = int(duration_str)
                    except ValueError:
                        entry['duration'] = 0
                    entry['status'] = parts[5].strip()
                else:
                    # Format FAILED sans durée
                    entry['duration'] = 0
                    entry['status'] = parts[4].strip()

                # Parser le timestamp
                try:
                    entry['datetime'] = datetime.strptime(
                        entry['timestamp'], '%Y-%m-%d %H:%M:%S'
                    )
                except ValueError:
                    entry['datetime'] = None

                migrations.append(entry)
    return migrations


def parse_daemon_log(filepath):
    """Parse le fichier live-migrator.log pour les métriques"""
    metrics = []
    pattern_temp = re.compile(
        r'\[(.+?)\] \[WARN\] TEMPERATURE ALERT: (\d+)°C > (\d+)°C'
    )
    pattern_cpu = re.compile(
        r'\[(.+?)\] \[WARN\] CPU ALERT: (\d+)% > (\d+)%'
    )
    pattern_ram = re.compile(
        r'\[(.+?)\] \[WARN\] RAM ALERT: (\d+)% > (\d+)%'
    )

    with open(filepath, 'r') as f:
        for line in f:
            m = pattern_temp.search(line)
            if m:
                try:
                    metrics.append({
                        'datetime': datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'),
                        'type': 'temperature',
                        'value': int(m.group(2)),
                        'threshold': int(m.group(3))
                    })
                except ValueError:
                    pass
                continue

            m = pattern_cpu.search(line)
            if m:
                try:
                    metrics.append({
                        'datetime': datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'),
                        'type': 'cpu',
                        'value': int(m.group(2)),
                        'threshold': int(m.group(3))
                    })
                except ValueError:
                    pass
                continue

            m = pattern_ram.search(line)
            if m:
                try:
                    metrics.append({
                        'datetime': datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'),
                        'type': 'ram',
                        'value': int(m.group(2)),
                        'threshold': int(m.group(3))
                    })
                except ValueError:
                    pass
    return metrics


def generate_text_report(migrations, output_dir):
    """Génère un rapport statistique textuel"""
    report_path = os.path.join(output_dir, 'rapport_migrations.txt')

    total = len(migrations)
    success = sum(1 for m in migrations if m['status'] == 'OK')
    failed = total - success
    durations = [m['duration'] for m in migrations if m['status'] == 'OK' and m['duration'] > 0]

    reasons = Counter(m['reason'] for m in migrations)
    targets = Counter(m['target'] for m in migrations)
    vms = Counter(m['vm'] for m in migrations)

    with open(report_path, 'w') as f:
        f.write("=" * 60 + "\n")
        f.write("   RAPPORT D'ANALYSE DES MIGRATIONS\n")
        f.write("=" * 60 + "\n\n")

        f.write(f"Période : {migrations[0]['timestamp']} → {migrations[-1]['timestamp']}\n")
        f.write(f"Total migrations : {total}\n")
        f.write(f"  Réussies : {success} ({success/total*100:.1f}%)\n")
        f.write(f"  Échouées : {failed} ({failed/total*100:.1f}%)\n\n")

        if durations:
            f.write("--- Durées (migrations réussies) ---\n")
            f.write(f"  Minimum  : {min(durations)}s\n")
            f.write(f"  Maximum  : {max(durations)}s\n")
            f.write(f"  Moyenne  : {sum(durations)/len(durations):.1f}s\n")
            f.write(f"  Médiane  : {sorted(durations)[len(durations)//2]}s\n")
            f.write(f"  Total    : {sum(durations)}s ({sum(durations)/60:.1f} min)\n\n")

        f.write("--- Répartition par raison ---\n")
        for reason, count in reasons.most_common():
            f.write(f"  {reason:30s} : {count:3d} ({count/total*100:.1f}%)\n")
        f.write("\n")

        f.write("--- Répartition par nœud cible ---\n")
        for target, count in targets.most_common():
            f.write(f"  {target:30s} : {count:3d} ({count/total*100:.1f}%)\n")
        f.write("\n")

        f.write("--- VMs les plus migrées ---\n")
        for vm, count in vms.most_common(10):
            f.write(f"  VM {vm:10s} : {count:3d} fois\n")
        f.write("\n")

        # Tableau détaillé
        f.write("--- Détail de chaque migration ---\n")
        f.write(f"{'Date':20s} | {'VM':6s} | {'Cible':8s} | {'Raison':20s} | {'Durée':6s} | {'Statut':6s}\n")
        f.write("-" * 75 + "\n")
        for m in migrations:
            dur = f"{m['duration']}s" if m['duration'] > 0 else "N/A"
            f.write(f"{m['timestamp']:20s} | {m['vm']:6s} | {m['target']:8s} | {m['reason']:20s} | {dur:6s} | {m['status']:6s}\n")

    print(f"  ✓ {report_path}")
    return report_path


def plot_durations(migrations, output_dir):
    """Graphique : durée de chaque migration"""
    ok_migrations = [m for m in migrations if m['status'] == 'OK' and m['duration'] > 0]
    if not ok_migrations:
        print("  ⚠ Pas de migrations réussies pour tracer les durées")
        return

    fig, ax = plt.subplots(figsize=(12, 5))

    labels = [f"VM {m['vm']}\n→{m['target']}" for m in ok_migrations]
    durations = [m['duration'] for m in ok_migrations]
    colors = []
    for m in ok_migrations:
        if 'temperature' in m['reason']:
            colors.append('#e74c3c')  # rouge
        elif 'cpu' in m['reason']:
            colors.append('#f39c12')  # orange
        elif 'ram' in m['reason']:
            colors.append('#3498db')  # bleu
        elif 'maintenance' in m['reason']:
            colors.append('#2ecc71')  # vert
        else:
            colors.append('#95a5a6')  # gris

    bars = ax.bar(range(len(durations)), durations, color=colors, edgecolor='white', linewidth=0.5)

    # Étiquettes de durée sur chaque barre
    for bar, dur in zip(bars, durations):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                f'{dur}s', ha='center', va='bottom', fontsize=8, fontweight='bold')

    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=7)
    ax.set_ylabel('Durée (secondes)')
    ax.set_title('Durée de chaque migration')
    ax.grid(axis='y', alpha=0.3)

    # Légende
    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor='#e74c3c', label='Température'),
        Patch(facecolor='#f39c12', label='CPU'),
        Patch(facecolor='#3498db', label='RAM'),
        Patch(facecolor='#2ecc71', label='Maintenance'),
    ]
    ax.legend(handles=legend_elements, loc='upper right')

    plt.tight_layout()
    path = os.path.join(output_dir, 'migration_durations.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def plot_success_rate(migrations, output_dir):
    """Graphique : taux de succès/échec (pie chart)"""
    success = sum(1 for m in migrations if m['status'] == 'OK')
    failed = len(migrations) - success

    fig, ax = plt.subplots(figsize=(6, 6))
    sizes = [success, failed]
    labels = [f'Réussies\n({success})', f'Échouées\n({failed})']
    colors = ['#2ecc71', '#e74c3c']
    explode = (0.05, 0.05)

    ax.pie(sizes, explode=explode, labels=labels, colors=colors,
           autopct='%1.1f%%', shadow=True, startangle=90,
           textprops={'fontsize': 12, 'fontweight': 'bold'})
    ax.set_title('Taux de succès des migrations', fontsize=14, fontweight='bold')

    plt.tight_layout()
    path = os.path.join(output_dir, 'migration_success_rate.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def plot_timeline(migrations, output_dir):
    """Graphique : timeline des migrations"""
    dated = [m for m in migrations if m['datetime'] is not None]
    if not dated:
        return

    fig, ax = plt.subplots(figsize=(14, 5))

    for m in dated:
        color = '#2ecc71' if m['status'] == 'OK' else '#e74c3c'
        marker = 'o' if m['status'] == 'OK' else 'x'
        size = max(m['duration'] * 3, 30) if m['duration'] > 0 else 30
        ax.scatter(m['datetime'], m['vm'], color=color, marker=marker,
                   s=size, zorder=5, edgecolors='white', linewidth=0.5)

    ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator())
    plt.xticks(rotation=45)
    ax.set_xlabel('Heure')
    ax.set_ylabel('VM ID')
    ax.set_title('Timeline des migrations')
    ax.grid(alpha=0.3)

    # Légende
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker='o', color='w', markerfacecolor='#2ecc71',
               markersize=10, label='Réussie'),
        Line2D([0], [0], marker='x', color='#e74c3c', markersize=10,
               label='Échouée', linestyle='None'),
    ]
    ax.legend(handles=legend_elements)

    plt.tight_layout()
    path = os.path.join(output_dir, 'migration_timeline.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def plot_by_reason(migrations, output_dir):
    """Graphique : répartition par raison (bar chart)"""
    reasons = Counter()
    for m in migrations:
        r = m['reason']
        if 'temperature' in r:
            reasons['Température'] += 1
        elif 'cpu' in r:
            reasons['CPU'] += 1
        elif 'ram' in r:
            reasons['RAM'] += 1
        elif 'maintenance' in r:
            reasons['Maintenance'] += 1
        elif 'manual' in r:
            reasons['Manuel'] += 1
        else:
            reasons[r] += 1

    fig, ax = plt.subplots(figsize=(8, 5))
    color_map = {
        'Température': '#e74c3c',
        'CPU': '#f39c12',
        'RAM': '#3498db',
        'Maintenance': '#2ecc71',
        'Manuel': '#9b59b6',
    }
    labels = list(reasons.keys())
    values = list(reasons.values())
    colors = [color_map.get(l, '#95a5a6') for l in labels]

    bars = ax.bar(labels, values, color=colors, edgecolor='white', linewidth=0.5)
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.2,
                str(val), ha='center', fontweight='bold')

    ax.set_ylabel('Nombre de migrations')
    ax.set_title('Migrations par raison de déclenchement')
    ax.grid(axis='y', alpha=0.3)

    plt.tight_layout()
    path = os.path.join(output_dir, 'migration_by_reason.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def plot_by_target(migrations, output_dir):
    """Graphique : répartition par nœud cible"""
    targets = Counter(m['target'] for m in migrations)

    fig, ax = plt.subplots(figsize=(8, 5))
    colors = ['#3498db', '#2ecc71', '#f39c12', '#e74c3c', '#9b59b6']
    labels = list(targets.keys())
    values = list(targets.values())

    bars = ax.bar(labels, values, color=colors[:len(labels)],
                  edgecolor='white', linewidth=0.5)
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.2,
                str(val), ha='center', fontweight='bold')

    ax.set_ylabel('Nombre de migrations reçues')
    ax.set_title('Répartition des migrations par nœud cible')
    ax.grid(axis='y', alpha=0.3)

    plt.tight_layout()
    path = os.path.join(output_dir, 'migration_by_target.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def plot_metrics(metrics, output_dir):
    """Graphique : métriques CPU/RAM/Temp au fil du temps"""
    if not metrics:
        print("  ⚠ Pas de métriques d'alerte dans les logs")
        return

    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)

    metric_types = ['temperature', 'cpu', 'ram']
    titles = ['Température CPU (°C)', 'Charge CPU (%)', 'Utilisation RAM (%)']
    colors = ['#e74c3c', '#f39c12', '#3498db']

    for ax, mtype, title, color in zip(axes, metric_types, titles, colors):
        data = [m for m in metrics if m['type'] == mtype]
        if data:
            times = [m['datetime'] for m in data]
            values = [m['value'] for m in data]
            threshold = data[0]['threshold']

            ax.plot(times, values, color=color, marker='o', markersize=3,
                    linewidth=1.5, label='Valeur mesurée')
            ax.axhline(y=threshold, color='red', linestyle='--', alpha=0.7,
                       label=f'Seuil ({threshold})')
            ax.fill_between(times, values, alpha=0.1, color=color)
            ax.legend(loc='upper right')

        ax.set_ylabel(title)
        ax.grid(alpha=0.3)

    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
    plt.xticks(rotation=45)
    axes[-1].set_xlabel('Heure')
    axes[0].set_title('Métriques système au fil du temps (alertes uniquement)')

    plt.tight_layout()
    path = os.path.join(output_dir, 'metrics_over_time.png')
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  ✓ {path}")


def main():
    if len(sys.argv) < 2:
        print("Usage : python3 analyze_migrations.py <fichier_log> [--output-dir <dossier>]")
        print("")
        print("Fichiers acceptés :")
        print("  - migration_history.log  (historique des migrations)")
        print("  - live-migrator.log      (logs du daemon, pour les métriques)")
        print("")
        print("Exemples :")
        print("  python3 analyze_migrations.py /var/lib/live-migrator/migration_history.log")
        print("  python3 analyze_migrations.py /var/log/live-migrator.log --output-dir ./resultats")
        print("  python3 analyze_migrations.py migration_history.log live-migrator.log")
        sys.exit(1)

    # Parser les arguments
    files = []
    output_dir = './resultats_analyse'
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == '--output-dir' and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        else:
            files.append(sys.argv[i])
            i += 1

    os.makedirs(output_dir, exist_ok=True)

    if not HAS_MATPLOTLIB:
        print("⚠ matplotlib non installé. Installation :")
        print("  pip3 install matplotlib")
        print("  ou : apt install python3-matplotlib")
        print("")
        print("Génération du rapport textuel uniquement...")

    # Identifier les fichiers
    history_file = None
    daemon_file = None
    for f in files:
        if not os.path.exists(f):
            print(f"Erreur : fichier '{f}' non trouvé")
            sys.exit(1)
        # Détecter le type de fichier
        with open(f, 'r') as fh:
            first_line = fh.readline()
            if '|' in first_line and 'VM=' in first_line:
                history_file = f
            else:
                daemon_file = f

    print(f"\n{'='*50}")
    print(f"  ANALYSE DES MIGRATIONS")
    print(f"{'='*50}\n")

    # Analyser l'historique
    if history_file:
        print(f"Fichier historique : {history_file}")
        migrations = parse_history_log(history_file)
        print(f"  {len(migrations)} migrations trouvées\n")

        if migrations:
            print("Génération du rapport textuel...")
            generate_text_report(migrations, output_dir)

            if HAS_MATPLOTLIB:
                print("\nGénération des graphiques...")
                plot_durations(migrations, output_dir)
                plot_success_rate(migrations, output_dir)
                plot_timeline(migrations, output_dir)
                plot_by_reason(migrations, output_dir)
                plot_by_target(migrations, output_dir)
    else:
        print("⚠ Aucun fichier migration_history.log fourni")

    # Analyser les métriques du daemon
    if daemon_file:
        print(f"\nFichier daemon : {daemon_file}")
        metrics = parse_daemon_log(daemon_file)
        print(f"  {len(metrics)} alertes trouvées")

        if HAS_MATPLOTLIB and metrics:
            print("\nGénération du graphique de métriques...")
            plot_metrics(metrics, output_dir)

    print(f"\n{'='*50}")
    print(f"  Résultats dans : {output_dir}/")
    print(f"{'='*50}\n")


if __name__ == '__main__':
    main()
