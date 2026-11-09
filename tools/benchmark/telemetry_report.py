"""Validate phase accounting and preserve scoped cumulative counter deltas."""
from decimal import Decimal,localcontext
import json
from pathlib import Path


def delta(before,after,kind):
    scope=before.get('scope')
    def missing(reason):return dict(state='unavailable',value=None,reason=reason,scope=scope)
    if before['state']!='available' or after['state']!='available':return missing('endpoint_unavailable')
    a,b=before['value'],after['value']
    if kind!='storage' and (a.get('stats_reset') is None or a.get('stats_reset')!=b.get('stats_reset')):return missing('counter_reset_or_unknown_epoch')
    values={}
    try:
        for key in (a.keys() | b.keys())-{'stats_reset','track_io_timing'}:
            if key not in a or key not in b:
                values[key]=dict(state='unavailable',value=None,reason='counter_missing');continue
            if key.endswith('_time_ms') and (a.get('track_io_timing')!='on' or b.get('track_io_timing')!='on'):
                values[key]=dict(state='unavailable',value=None,reason='track_io_timing_disabled');continue
            with localcontext() as context:
                context.prec=max(len(str(a[key]))+len(str(b[key]))+8,40)
                x,y=Decimal(a[key]),Decimal(b[key]);n=y-x
                if not x.is_finite() or not y.is_finite() or (kind!='storage' and n<0):return missing('counter_decreased_or_invalid')
                values[key]=dict(state='available',value=format(n,'f'),reason=None)
    except (ValueError,TypeError,ArithmeticError):return missing('invalid_counter')
    return dict(state='available',value=values,reason=None,scope=scope)


def phases(path):
    path=Path(path)
    if path.stat().st_size>64*1024**2:raise ValueError('Phase journal byte budget exceeded')
    begun={};ends={};summary=None;backends=[];active=[]
    with path.open() as stream:
        for index,line in enumerate(stream):
            if index>=10000 or len(line)>1048576:raise ValueError('Phase journal record budget exceeded')
            row=json.loads(line)
            if row['event']=='begin':
                if row['id'] in begun:raise ValueError('Duplicate phase id')
                if row['parent'] is not None and (row['parent'] not in begun or row['parent'] in ends):raise ValueError('Invalid phase parent')
                if row['parent']!=(active[-1] if active else None):raise ValueError('Invalid phase nesting')
                begun[row['id']]=row;active.append(row['id'])
            elif row['event']=='end':
                i=row['id']
                if i not in begun or i in ends:raise ValueError('Missing/duplicate phase start')
                if not active or active.pop()!=i:raise ValueError('Invalid phase completion order')
                start=begun[i]
                if row['parent']!=start['parent'] or row['phase']!=start['phase'] or row['elapsed_seconds']<start['elapsed_seconds']:raise ValueError('Phase context mismatch')
                if row['wall_seconds']<0 or row['R_self_CPU_seconds']<0:raise ValueError('Invalid phase duration')
                if row['status'] not in ['completed','failed']:raise ValueError('Invalid phase status')
                row['counter_deltas']={k:delta(row['before'][k],row['after'][k],k) for k in ['database','wal','storage']} if row['before'] is not None and row['after'] is not None else None
                ends[i]=row
            elif row['event']=='summary':
                if summary is not None:raise ValueError('Duplicate phase summary')
                summary=row
            elif row['event']=='backend':backends.append(row['pid'])
            else:raise ValueError('Unknown phase journal event')
    return dict(complete=begun.keys()==ends.keys() and summary is not None,phases=list(ends.values()),unfinished_ids=sorted(begun.keys()-ends.keys()),summary=summary,
        backend_session_leaders=sorted(set(backends)),accounting='inclusive nested phase/method/SQL times overlap; never add across levels; observer queries and timers perturb results')
