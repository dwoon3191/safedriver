/* Company fleet parser: only the current fleet sheet, never historic/scrapped tabs. */
(function (root) {
  'use strict';
  function parse(sheets) {
    const sheet = sheets.find(s => s.name.trim() === '대운교통 차량종합');
    if (!sheet) throw new Error('대운교통 차량종합 시트가 없습니다. 원본 차량현황 파일을 선택하세요.');
    const headerRow = sheet.rows.findIndex(row => row.some(v => String(v).replace(/\s/g, '') === '차량번호'));
    if (headerRow < 0) throw new Error('차량번호 열을 찾지 못했습니다.');
    const column = sheet.rows[headerRow].findIndex(v => String(v).replace(/\s/g, '') === '차량번호');
    const vehicles = [], invalid = [], duplicates = [], seen = new Set();
    sheet.rows.slice(headerRow + 1).forEach((row, offset) => {
      const value = String(row[column] ?? '').replace(/\s/g, '');
      if (!value) return;
      if (!/^[가-힣]{2}[0-9]{2,3}[가-힣][0-9]{4}$/.test(value)) {
        invalid.push(`${headerRow + offset + 2}행: ${value}`); return;
      }
      if (seen.has(value)) duplicates.push(value);
      else { seen.add(value); vehicles.push(value); }
    });
    if (invalid.length) throw new Error(`차량번호를 확인하세요: ${invalid.slice(0, 5).join(', ')}`);
    if (!vehicles.length || vehicles.length > 2000) throw new Error('등록 가능한 차량번호가 없거나 2000대를 초과했습니다.');
    if (duplicates.length) throw new Error(`차량번호가 중복됩니다: ${duplicates.slice(0, 5).join(', ')}`);
    return vehicles.sort();
  }
  function diff(previous, next) {
    const a = new Set(previous), b = new Set(next);
    return { added: next.filter(x => !a.has(x)), removed: previous.filter(x => !b.has(x)) };
  }
  root.DaewoonFleet = { parse, diff };
})(typeof window === 'undefined' ? globalThis : window);
