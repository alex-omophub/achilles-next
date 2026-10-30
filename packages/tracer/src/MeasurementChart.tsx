import {Bar, CartesianGrid, ComposedChart, Legend, Line, ResponsiveContainer, Tooltip, XAxis, YAxis} from 'recharts';
export default function MeasurementChart({data}: {data: {month: string; records: number; people: number}[]}) {
  return <ResponsiveContainer width="100%" height={260}><ComposedChart data={data} margin={{top: 12, right: 18, left: 0, bottom: 0}} accessibilityLayer>
    <CartesianGrid vertical={false} stroke="#e1e7ec"/><XAxis dataKey="month" tick={{fontSize: 12}}/><YAxis allowDecimals={false} width={48}/>
    <Tooltip/><Legend/><Bar dataKey="records" name="Measurement records" fill="#176e80" radius={[3, 3, 0, 0]} maxBarSize={32}/>
    <Line type="linear" dataKey="people" name="Distinct tested people" stroke="#92500c" strokeWidth={2} dot={{r: 3}}/>
  </ComposedChart></ResponsiveContainer>;
}
