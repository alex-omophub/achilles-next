import {BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer} from 'recharts';

export default function ObservationChart({data}: {data: {month: string; count: number}[]}) {
  return <ResponsiveContainer width="100%" height={240} minWidth={0}>
    <BarChart data={data} accessibilityLayer>
      <CartesianGrid vertical={false} stroke="#e1e7ec"/><XAxis dataKey="month" tickLine={false}/>
      <YAxis allowDecimals={false} width={55}/><Tooltip/>
      <Bar dataKey="count" name="Observed people" fill="#176e80" isAnimationActive={false}/>
    </BarChart>
  </ResponsiveContainer>;
}
