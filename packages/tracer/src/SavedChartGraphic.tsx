import {useMemo} from 'react';
import {Bar, CartesianGrid, ComposedChart, Line, ResponsiveContainer, Tooltip, XAxis, YAxis} from 'recharts';
import type {ChartPoint} from './saved-chart';

export default function SavedChartGraphic({points, quantiles, measure, locale}: {locale?: string; points: ChartPoint[]; quantiles: boolean; measure: string}) {
  const ticks = useMemo(() => locale ? new Intl.NumberFormat(locale, {maximumSignificantDigits: 17}) : undefined, [locale]);
  return <ResponsiveContainer width="100%" height={220} minWidth={0}>
    <ComposedChart data={points} margin={{top: 12, right: 12, left: 2, bottom: 4}} accessibilityLayer>
      <CartesianGrid vertical={false} stroke="var(--rule)" strokeDasharray="3 4"/>
      <XAxis dataKey="label" tickLine={false} tick={{fill: 'var(--muted)', fontSize: 12}} stroke="var(--rule)" minTickGap={10}/>
      <YAxis tickFormatter={ticks?.format} allowDecimals={quantiles} width="auto" tick={{fill: 'var(--muted)', fontSize: 12}} stroke="var(--rule)"
        domain={quantiles ? ['auto', 'auto'] : [0, 'auto']}/>
      <Tooltip isAnimationActive={false} filterNull={false} content={({active, payload}) => {
        const point: ChartPoint | undefined = payload?.[0]?.payload;
        return active && point ? <div className="publication-chart-tip"><strong>{point.detail}</strong>
          <span>{measure} · {point.exact ?? 'Unavailable'}</span></div> : null;
      }}/>
      {quantiles ? <Line dataKey="position" stroke="none" dot={{r: 5, fill: 'var(--accent)', stroke: 'var(--surface)'}}
        activeDot={{r: 6, fill: 'var(--accent)'}} isAnimationActive={false}/>
        : <Bar dataKey="position" fill="var(--accent)" maxBarSize={38} isAnimationActive={false}/>}
    </ComposedChart>
  </ResponsiveContainer>;
}
