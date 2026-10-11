/* Fixed examples only. The landing has no model endpoints or account integration. */
const modes = {
  text: {
    titles: ['텍스트 선택', '단축키 누르기', '설명 확인', '직접 복사'],
    copies: ['궁금한 부분을 드래그합니다.', '⌘ ⇧ 0으로 설명을 요청합니다.', '결과 창에서 내용을 검토합니다.', '필요한 내용만 복사해 가져갑니다.'],
    actions: ['텍스트 선택하기', '⌘ ⇧ 0 누르기', '설명 확인하기', '복사 흐름 보기', '처음부터 보기'],
    statuses: ['아래 버튼으로 고정 예시를 살펴보세요.', '선택한 텍스트만 요청에 담습니다.', '앱에서는 선택한 연결로 설명을 요청합니다.', '설명은 자동 복사되지 않습니다. 직접 읽고 복사하세요.', '앱에서 복사 버튼을 누른 뒤 직접 붙여넣습니다.'],
    heading: '이진 탐색 이해하기', intro: '정렬된 배열에서 원하는 값을 찾고 싶다.',
    input: '이진 탐색은 왜 O(log n)일까?\n탐색 범위가 줄어드는 과정을 설명해줘.', shortcut: '⌘ ⇧ 0',
    response: '한 번 비교할 때마다 탐색 범위가 절반으로 줄어듭니다. n개의 원소에서 시작하면 약 log₂ n번 비교한 뒤 하나의 후보만 남습니다.'
  },
  image: {
    titles: ['단축키 누르기', '영역 선택', '설명 확인', '직접 복사'],
    copies: ['⌘ ⇧ 9로 캡처를 시작합니다.', '보고 싶은 그림 영역만 선택합니다.', '캡처와 설명을 함께 검토합니다.', '필요한 내용만 직접 복사합니다.'],
    actions: ['⌘ ⇧ 9 누르기', '영역 선택하기', '설명 확인하기', '복사 흐름 보기', '처음부터 보기'],
    statuses: ['캡처는 단축키부터 시작합니다.', '앱에서는 십자 커서로 영역을 고릅니다.', '직접 선택한 화면 영역만 이미지로 전송합니다.', '결과 창에서 그림과 설명을 검토합니다.', '일반 설명은 복사 버튼을 눌러 가져갑니다.'],
    heading: '탐색 범위, 반씩 줄이기', intro: '도표도 필요한 부분만 골라보자.',
    input: '16개 → 8개 → 4개 → 2개 → 1개\n이 그림에서 탐색 범위는 어떻게 바뀔까?', shortcut: '⌘ ⇧ 9',
    response: '각 화살표를 지날 때 후보 개수가 절반으로 줄어듭니다. 16개에서 시작하면 4번 줄인 뒤 1개가 남습니다. 이 구조가 이진 탐색의 O(log n)을 설명합니다.'
  },
  code: {
    titles: ['문제 선택', '단축키 누르기', '코드 자동 복사', '직접 붙여넣기'],
    copies: ['원하는 언어와 함께 선택합니다.', '⌘ ⇧ 8로 코드 바로 복사를 실행합니다.', '복사 대상을 확정하면 코드만 복사합니다.', '직접 ⌘V로 붙여넣고 검토합니다.'],
    actions: ['문제 선택하기', '⌘ ⇧ 8 누르기', '복사 흐름 보기', '붙여넣기 흐름 보기', '처음부터 보기'],
    statuses: ['앱에서는 결과 창 없이 코드를 복사합니다.', '본문에 지정한 코드 언어를 우선합니다.', '앱에서는 코드를 요청하고 복사 대상을 확인합니다.', '성공 시 코드만 자동 복사합니다. 이 데모는 클립보드를 변경하지 않습니다.', '앱에서는 직접 ⌘V로 붙여넣습니다. 아래는 고정된 코드 예시입니다.'],
    heading: '이진 탐색 구현하기', intro: '원하는 코드 언어도 함께 알려주세요.',
    input: '정렬된 배열에서 원하는 값을 찾는\n이진 탐색을 Python 코드로 만들어줘.', shortcut: '⌘ ⇧ 8',
    response: '붙여넣은 코드 예시 · 입력 배열은 정렬되어 있어야 합니다.'
  },
  captureCode: {
    titles: ['단축키 누르기', '문제 영역 선택', '코드 자동 복사', '직접 붙여넣기'],
    copies: ['⌘ ⇧ 7로 캡처 → 코드를 시작합니다.', '문제와 조건이 보이는 영역만 드래그합니다.', '결과 창 없이 코드만 클립보드로 받습니다.', '직접 ⌘V로 붙여넣고 검토합니다.'],
    actions: ['⌘ ⇧ 7 누르기', '문제 영역 선택하기', '복사 흐름 보기', '붙여넣기 흐름 보기', '처음부터 보기'],
    statuses: ['텍스트 선택 없이 단축키부터 시작합니다.', '앱에서는 문제 영역만 드래그해 캡처합니다.', '선택한 이미지 한 장으로 코드를 요청합니다.', '성공 시 코드만 자동 복사합니다. 이 데모는 클립보드를 변경하지 않습니다.', '앱에서는 직접 ⌘V로 붙여넣습니다. 아래는 고정된 코드 예시입니다.'],
    heading: '그림 문제에서 코드까지', intro: '복사하기 어려운 문제도 영역만 선택하세요.',
    input: '정렬된 배열에서 원하는 값을 찾는\n이진 탐색을 Python 코드로 만들어줘.', shortcut: '⌘ ⇧ 7',
    response: '붙여넣은 코드 예시 · 입력 배열은 정렬되어 있어야 합니다.'
  }
};
const $ = id => document.getElementById(id);
let currentMode = 'text';
let step = 0;
let copySequence = 0;
let installSequence = 0;
const copiesCode = () => currentMode === 'code' || currentMode === 'captureCode';

function render() {
  const data = modes[currentMode];
  const capture = currentMode === 'image' || currentMode === 'captureCode';
  document.querySelectorAll('[data-mode]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mode === currentMode)));
  document.querySelectorAll('.demo-steps li').forEach((item, index) => {
    if (index === Math.min(step, 3)) item.setAttribute('aria-current', 'step');
    else item.removeAttribute('aria-current');
  });
  for (let i = 0; i < 4; i++) {
    document.querySelector(`[data-step-title="${i}"]`).textContent = data.titles[i];
    document.querySelector(`[data-step-copy="${i}"]`).textContent = data.copies[i];
  }
  $('demo-next').replaceChildren(document.createTextNode(data.actions[step] + ' '));
  const arrow = document.createElement('span');
  arrow.textContent = '→'; arrow.setAttribute('aria-hidden', 'true'); $('demo-next').append(arrow);
  $('demo-status').textContent = data.statuses[step];
  $('example-heading').textContent = data.heading;
  $('example-intro').textContent = data.intro;
  $('example-input').textContent = data.input;
  $('example-input').style.whiteSpace = 'pre-line';
  $('example-response').textContent = data.response;
  $('shortcut-hint').textContent = data.shortcut;
  $('shortcut-hint').classList.toggle('active', step >= (capture ? 1 : 2));
  $('demo-selection').classList.toggle('selected', step >= (capture ? 2 : 1));
  $('demo-selection').classList.toggle('capture', capture && step >= 2);
  $('response-preview').hidden = copiesCode() ? step < 4 : step < 3;
  $('clipboard-preview').hidden = !copiesCode() || step < 3 || step === 4;
  $('example-code').hidden = !copiesCode();
  $('copy-example').textContent = copiesCode() ? '예시 코드 복사' : '예시 설명 복사';
  $('copy-state').textContent = copiesCode() ? '코드를 검토하고 직접 사용하세요.' : step === 4 ? '앱에서도 직접 복사 버튼을 누릅니다.' : '내용을 검토한 뒤 복사하세요.';
}
document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => {
  currentMode = button.dataset.mode; step = 0; copySequence++; render();
}));
$('demo-next').addEventListener('click', () => { step = step === 4 ? 0 : step + 1; copySequence++; render(); });
$('demo-reset').addEventListener('click', () => { step = 0; copySequence++; render(); });

async function copyText(text) {
  if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
  await navigator.clipboard.writeText(text);
}
$('copy-example').addEventListener('click', async () => {
  const sequence = ++copySequence;
  const text = copiesCode() ? $('example-code').textContent : modes[currentMode].response;
  try {
    await copyText(text);
    if (sequence === copySequence) $('copy-state').textContent = '예시를 복사했습니다. 붙여넣기는 직접 하세요.';
  } catch {
    if (sequence === copySequence) $('copy-state').textContent = '복사하지 못했습니다. 예시 내용을 직접 선택해 복사하세요.';
  }
});
$('copy-install').addEventListener('click', async () => {
  const sequence = ++installSequence;
  try {
    await copyText($('install-command').textContent);
    if (sequence === installSequence) $('install-copy-status').textContent = '설치 명령을 복사했습니다.';
  } catch {
    if (sequence === installSequence) $('install-copy-status').textContent = '복사하지 못했습니다. 명령을 직접 선택해 복사하세요.';
  }
});
render();
